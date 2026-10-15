#!/usr/bin/env bash
# Lint de las skills (skill/*/SKILL.md) y del README:
# - frontmatter entre líneas --- con name y description no vacíos; name = carpeta;
# - las rutas del repo citadas (`local/...`, `hooks/...`, `cloud/...`, `skill/...`, `tests/...`,
#   `.github/...` y links relativos) existen;
# - sin valores con pinta de reales (ids de canal/usuario, tokens, webhooks, sesiones);
# - la skill de setup tiene la regla de colisión por substring y menciona local/check-slugs;
# - sin canal hardcodeado: el único canal permitido es #<canal>;
# - la skill de tareas declara la nube por defecto (`claude --cloud`) y local como fallback,
#   el aviso de arranque con el link de la sesión y el diálogo de confianza;
# - ninguna skill sugiere esperar con pgrep (solo se permite la regla que lo prohíbe);
# - las skills piden la línea `notify: <slug>` en el prompt (nube y local);
# - ningún archivo trackeado menciona el archivo por carpeta ni la variable de tarea removidos.
# Uso: bash tests/lint-skills.sh   — sale ≠0 si falla algún caso.

set -u

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir" || exit 1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "${2%$'\n'}" | sed 's/^/     /'; }

# Patrones armados por concatenación para que este archivo no se detecte a sí mismo.
secret_patterns=(
  'C''0[A-Z0-9]{8,}'
  'U''0[A-Z0-9]{8,}'
  'xo''x[bpa]-[0-9]'
  'automations/''webhook/[0-9a-f]{8}'
  'session''_01'
  'cse''_01'
)
# Placeholders permitidos (se borran de la línea antes de buscar).
strip_placeholders() { sed -e 's/C0123456789//g' -e 's/U0123456789//g' -e 's/xoxb-REPLACE_ME//g'; }

skills=(skill/*/SKILL.md)
docs=("${skills[@]}" README.md)

# 1. Frontmatter.
for f in "${skills[@]}"; do
  dir=$(basename "$(dirname "$f")")
  problems=""
  if [ "$(head -n 1 "$f")" != "---" ]; then
    problems+="no empieza con ---"$'\n'
  fi
  # Líneas entre el primer --- y el segundo.
  fm=$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { closed = 1; exit } inside { print } END { if (!closed) print "__SIN_CIERRE__" }' "$f")
  if printf '%s\n' "$fm" | grep -qx '__SIN_CIERRE__'; then
    problems+="frontmatter sin --- de cierre"$'\n'
  fi
  name=$(printf '%s\n' "$fm" | sed -nE 's/^name:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | head -n 1)
  [ -n "$name" ] || problems+="name vacío o ausente"$'\n'
  [ -z "$name" ] || [ "$name" = "$dir" ] || problems+="name '$name' ≠ carpeta '$dir'"$'\n'
  # description: valor en la misma línea, o bloque (>-, |) con al menos una línea indentada no vacía.
  desc=$(printf '%s\n' "$fm" | awk '
    /^description:/ {
      v = $0; sub(/^description:[[:space:]]*/, "", v)
      if (v !~ /^[>|][-+]?[[:space:]]*$/) { print v; exit }
      block = 1; next
    }
    block && /^[[:space:]]+[^[:space:]]/ { print; exit }
    block && /^[^[:space:]]/ { exit }')
  [ -n "$(printf '%s' "$desc" | tr -d '[:space:]')" ] || problems+="description vacía o ausente"$'\n'
  if [ -z "$problems" ]; then ok "frontmatter $f"; else ko "frontmatter $f" "$problems"; fi
done

# 2. Rutas del repo citadas en skills y README.
bt='`'
path_re="${bt}(local|hooks|cloud|skill|tests|\.github)/[^${bt} ]*"
missing=""
for f in "${docs[@]}"; do
  base=$(dirname "$f")
  # `ruta` en backticks, relativa a la raíz del repo.
  while IFS= read -r p; do
    case "$p" in *'<'* | *'>'*) continue ;; esac
    p="${p%[.,:;)]}"
    if [[ "$p" == *'*'* ]]; then
      compgen -G "$p" >/dev/null || missing+="$f: \`$p\`"$'\n'
    elif [ ! -e "$p" ]; then
      missing+="$f: \`$p\`"$'\n'
    fi
  done < <(grep -oE "$path_re" "$f" | sed 's/^.//')
  # Links markdown relativos, resueltos desde la carpeta del archivo.
  while IFS= read -r p; do
    case "$p" in http* | '#'* | mailto:*) continue ;; esac
    p="${p%%#*}"
    [ -n "$p" ] || continue
    [ -e "$base/$p" ] || missing+="$f: ($p)"$'\n'
  done < <(grep -oE '\]\([^)[:space:]]+\)' "$f" | sed -e 's/^](//' -e 's/)$//')
done
if [ -z "$missing" ]; then ok "rutas citadas existen"; else ko "rutas citadas que no existen" "$missing"; fi

# 3. Sin valores con pinta de reales.
leaks=""
for f in "${docs[@]}"; do
  for pat in "${secret_patterns[@]}"; do
    hits=$(strip_placeholders <"$f" | grep -nE -- "$pat")
    [ -z "$hits" ] || leaks+="$f ($pat):"$'\n'"$hits"$'\n'
  done
done
if [ -z "$leaks" ]; then ok "sin ids/tokens con pinta de reales"; else ko "valores con pinta de reales" "$leaks"; fi

# 4. Skill de setup: regla de colisión y helper.
setup=skill/claude-code-notify-setup/SKILL.md
missing_rule=""
for needle in 'substring' 'colisión por substring' 'notify-dev-ml' 'local/check-slugs' 'SendToAgent' 'C0123456789'; do
  grep -qF -- "$needle" "$setup" || missing_rule+="falta '$needle'"$'\n'
done
if [ -z "$missing_rule" ]; then ok "skill de setup: regla de colisión + local/check-slugs"; else ko "skill de setup" "$missing_rule"; fi

# 5. Sin canal hardcodeado: solo #<canal>. Se ignoran headings markdown (#… al principio
#    seguido de espacio o #), anchors de links ](#…) y ${#var}.
chans=""
for f in "${docs[@]}"; do
  hits=$(sed -E -e 's/^#+[[:space:]].*$//' -e 's/\]\(#[^)]*\)//g' -e 's/\$\{#//g' "$f" |
    grep -nE '(^|[^[:alnum:]&/#])#[a-z][a-z0-9_-]+')
  [ -z "$hits" ] || chans+="$f:"$'\n'"$hits"$'\n'
done
if [ -z "$chans" ]; then ok "sin canal hardcodeado (solo #<canal>)"; else ko "canal hardcodeado" "$chans"; fi

# 6. Las skills usan el placeholder #<canal> y no otros nombres de canal entre <>.
bad_ph=$(grep -noE '#<[^>]*>' "${skills[@]}" | grep -v ':#<canal>$')
if [ -z "$bad_ph" ] && grep -qF '#<canal>' "${skills[@]}"; then
  ok "skills usan #<canal>"
else
  ko "skills con otro placeholder de canal" "$bad_ph"
fi

# 7. Skill de tareas: la nube es el modo por defecto y local es el fallback.
task=skill/claude-code-task/SKILL.md
missing_cloud=""
grep -qE '^## .*nube.*por defecto' "$task" || missing_cloud+="falta un heading de pasos en la nube 'por defecto'"$'\n'
grep -qF -- 'claude --cloud' "$task" || missing_cloud+="falta 'claude --cloud'"$'\n'
grep -qF -- "script -qec 'claude --cloud" "$task" || missing_cloud+="falta el lanzamiento sin TTY con script -qec"$'\n'
grep -qE '^## .*[Ll]ocal.*fallback' "$task" || missing_cloud+="falta un heading de alternativa local 'fallback'"$'\n'
desc_task=$(awk 'NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$task")
printf '%s\n' "$desc_task" | grep -q 'nube' || missing_cloud+="la description no menciona la nube"$'\n'
printf '%s\n' "$desc_task" | grep -q 'fallback' || missing_cloud+="la description no menciona local como fallback"$'\n'
grep -qF -- 'Ya arrancó la [sesión de Claude Code de <tarea>](https://claude.ai/code/<session id>)' "$task" || missing_cloud+="falta el aviso de arranque con el link de la sesión"$'\n'
grep -qF -- 'hasTrustDialogAccepted' "$task" || missing_cloud+="falta el troubleshooting del diálogo de confianza"$'\n'
if [ -z "$missing_cloud" ]; then ok "skill de tareas: nube por defecto, local como fallback"; else ko "skill de tareas: nube por defecto" "$missing_cloud"; fi

# 8. Ninguna skill sugiere pgrep para esperar (pgrep -f se matchea a sí mismo y el bucle no
#    termina). Una línea que nombra pgrep solo se acepta si es la prohibición: "nunca … pgrep"
#    en la misma oración. La skill de tareas tiene que tener esa regla.
pgrep_suggestions() {
  grep -niE '(^|[^[:alnum:]_-])pgrep([^[:alnum:]_-]|$)' -- "$1" | grep -viE 'nunca[^.]*pgrep'
}
pgrep_tmp=$(mktemp -d)
# shellcheck disable=SC2016 # backticks literales de markdown
printf 'Nunca esperes con `pgrep -f`.\n' >"$pgrep_tmp/prohibe.md"
# shellcheck disable=SC2016 # backticks literales de markdown
printf 'Esperá con `while pgrep -f claude; do sleep 5; done`.\n' >"$pgrep_tmp/sugiere.md"
pgrep_bad=""
[ -z "$(pgrep_suggestions "$pgrep_tmp/prohibe.md")" ] || pgrep_bad+="autotest: la regla que lo prohíbe dispara el chequeo"$'\n'
[ -n "$(pgrep_suggestions "$pgrep_tmp/sugiere.md")" ] || pgrep_bad+="autotest: un bucle con pgrep no dispara el chequeo"$'\n'
rm -rf "$pgrep_tmp"
for f in "${skills[@]}"; do
  hits=$(pgrep_suggestions "$f")
  [ -z "$hits" ] || pgrep_bad+="$f:"$'\n'"$hits"$'\n'
done
grep -qiE 'nunca[^.]*pgrep' "$task" || pgrep_bad+="$task: falta la regla 'nunca esperar con pgrep'"$'\n'
if [ -z "$pgrep_bad" ]; then ok "skills no sugieren pgrep para esperar"; else ko "skills sugieren pgrep para esperar" "$pgrep_bad"; fi

# 9. A quién avisar va en el prompt: las skills piden la línea `notify: <slug>` (la de tareas,
#    en el flujo de la nube y en el local).
notify_bad=""
for f in "${skills[@]}"; do
  grep -qF -- 'notify: <slug>' "$f" || notify_bad+="$f: falta la línea 'notify: <slug>'"$'\n'
done
grep -qE '^[[:space:]]*script -qec .claude --cloud "notify: <slug>$' "$task" ||
  notify_bad+="$task: el lanzamiento en la nube no empieza el prompt con 'notify: <slug>'"$'\n'
grep -qE 'notify-run -p "notify: <slug>$' "$task" ||
  notify_bad+="$task: el lanzamiento local no empieza el prompt con 'notify: <slug>'"$'\n'
if [ -z "$notify_bad" ]; then ok "skills piden la línea notify: <slug>"; else ko "skills sin la línea notify:" "$notify_bad"; fi

# 10. Nada removido sigue mencionado en el repo: ni el archivo por carpeta de antes ni la
#     variable de tarea. Patrones armados por concatenación para no detectarse a sí mismo.
removed=('\.claude''-notify' 'NOTIFY''_TASK')
removed_bad=""
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  for pat in "${removed[@]}"; do
    hits=$(grep -nE -- "$pat" "$f")
    [ -z "$hits" ] || removed_bad+="$f:"$'\n'"$hits"$'\n'
  done
done < <(git ls-files -z -co --exclude-standard)
if [ -z "$removed_bad" ]; then ok "sin menciones a configuración removida"; else ko "menciones a configuración removida" "$removed_bad"; fi

echo
echo "pasaron: $pass  fallaron: $fail"
[ "$fail" = 0 ]
