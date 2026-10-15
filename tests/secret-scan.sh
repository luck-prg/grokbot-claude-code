#!/usr/bin/env bash
# Busca tokens/ids con pinta de reales en los archivos trackeados y no ignorados del repo
# (git ls-files -co --exclude-standard). Solo se permiten los placeholders.
# Uso: bash tests/secret-scan.sh   — sale ≠0 si encuentra algo.

set -u

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir" || exit 1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "${2%$'\n'}" | sed 's/^/     /'; }

# Patrones armados por concatenación para que este archivo (y lint-skills.sh) no se detecten
# a sí mismos; así no hace falta excluir ningún archivo.
patterns=(
  'C''0[A-Z0-9]{8,}'
  'U''0[A-Z0-9]{8,}'
  'xo''x[bpa]-[0-9]'
  'automations/''webhook/[0-9a-f]{8}'
  'session''_01'
  'cse''_01'
  'bot-''notifications'
)
# Placeholders permitidos (se borran de la línea antes de buscar).
strip_placeholders() { sed -e 's/C0123456789//g' -e 's/U0123456789//g' -e 's/xoxb-REPLACE_ME//g'; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ko "no es un repo git"
  echo
  echo "pasaron: $pass  fallaron: $fail"
  exit 1
fi

files=()
while IFS= read -r -d '' f; do
  # Tracked pero borrado del working tree, o binario: se saltea.
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue
  files+=("$f")
done < <(git ls-files -z -co --exclude-standard)

if [ "${#files[@]}" -gt 0 ]; then
  ok "archivos a revisar: ${#files[@]}"
else
  ko "no hay archivos para revisar"
fi

for pat in "${patterns[@]}"; do
  hits=""
  for f in "${files[@]}"; do
    h=$(strip_placeholders <"$f" | grep -nE -- "$pat" | cut -c1-160)
    [ -z "$h" ] || hits+=$(printf '%s\n' "$h" | sed "s|^|$f:|")$'\n'
  done
  if [ -z "$hits" ]; then ok "sin /$pat/"; else ko "encontrado /$pat/" "$hits"; fi
done

echo
echo "pasaron: $pass  fallaron: $fail"
[ "$fail" = 0 ]
