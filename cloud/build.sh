#!/usr/bin/env bash
# Regenera cloud/setup.sh embebiendo hooks/notify.sh y hooks/settings.json.
# Uso: bash cloud/build.sh          (escribe cloud/setup.sh)
#      bash cloud/build.sh --check  (falla si cloud/setup.sh está desactualizado)

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$repo_dir/cloud/setup.sh"

render() {
  cat <<'HEADER'
#!/usr/bin/env bash
# grokbot-claude-code: setup script para environments de claude.ai/code.
# GENERADO por cloud/build.sh a partir de hooks/notify.sh y hooks/settings.json; no editar a mano.
#
# Pegalo entero en el "Setup script" del environment. Instala el hook de notificación
# dentro de la VM y lo agrega a ~/.claude/settings.json sin pisar lo existente.
#
# En el environment configurá:
#   - Network access: Custom, permitir slack.com (+ package managers por defecto).
#   - Network secret: Bearer para el host slack.com con el token xoxb- del bot.
#     El proxy inyecta el header Authorization solo en requests de la sesión
#     (no en las de este setup script), así que acá no se prueba el envío.
#   - Variables de entorno: SLACK_NOTIFY_CHANNEL=C0123456789 (id del canal).
#     A quién avisar sale de la línea `notify: <slug>` del prompt; NOTIFY_AGENT=<slug>
#     queda como fallback opcional (environment de un solo agente).
#
# Nunca hace fallar el setup: si algo sale mal, lo dice y sigue.

set -u

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
hook="$claude_dir/hooks/grokbot-notify.sh"
mkdir -p "$claude_dir/hooks"

cat >"$hook" <<'GROKBOT_NOTIFY_SH_EOF'
HEADER
  cat "$repo_dir/hooks/notify.sh"
  cat <<'MIDDLE'
GROKBOT_NOTIFY_SH_EOF
chmod 755 "$hook"

config_dir="$HOME/.config/grokbot-claude-code"
mkdir -p "$config_dir"
chmod 700 "$config_dir"
(
  umask 077
  printf 'SLACK_NOTIFY_CHANNEL=%s\n' "${SLACK_NOTIFY_CHANNEL:-C0123456789}" >"$config_dir/env"
)

new_hooks=$(cat <<'GROKBOT_SETTINGS_EOF'
MIDDLE
  cat "$repo_dir/hooks/settings.json"
  cat <<'FOOTER'
GROKBOT_SETTINGS_EOF
)

settings="$claude_dir/settings.json"
[ -s "$settings" ] || echo '{}' >"$settings"

if command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp "$settings.XXXXXX")
  if jq --argjson new "$new_hooks" '
      .hooks = (reduce ($new.hooks | to_entries[]) as $e (.hooks // {};
        .[$e.key] = ((.[$e.key] // []) as $cur |
          if any($cur[]?; any(.hooks[]?; (.command // "") | contains("grokbot-notify.sh")))
          then $cur
          else $cur + $e.value
          end)))' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"
    echo "grokbot-notify: no pude mergear $settings con jq" >&2
  fi
elif command -v python3 >/dev/null 2>&1; then
  NEW_HOOKS="$new_hooks" python3 - "$settings" <<'PY' || echo "grokbot-notify: no pude mergear $settings con python3" >&2
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    cur = json.load(f)
new = json.loads(os.environ["NEW_HOOKS"])
hooks = cur.setdefault("hooks", {})
for event, entries in new["hooks"].items():
    existing = hooks.setdefault(event, [])
    if not any("grokbot-notify.sh" in h.get("command", "")
               for e in existing for h in e.get("hooks", [])):
        existing.extend(entries)
with open(path, "w") as f:
    json.dump(cur, f, indent=2)
PY
else
  echo "grokbot-notify: falta jq y python3; no se configuraron los hooks" >&2
fi

echo "grokbot-notify: hook instalado en $hook"
exit 0
FOOTER
}

if [ "${1:-}" = "--check" ]; then
  if ! diff -q <(render) "$out" >/dev/null; then
    echo "cloud/setup.sh está desactualizado: corré bash cloud/build.sh" >&2
    exit 1
  fi
  exit 0
fi

render >"$out"
chmod 755 "$out"
echo "escrito $out"
