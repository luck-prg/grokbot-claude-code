#!/usr/bin/env bash
# grokbot-claude-code: instalación local.
#
# - Copia hooks/notify.sh a ~/.claude/hooks/grokbot-notify.sh
# - Copia local/notify-run a ~/.local/bin/notify-run
# - Agrega los hooks de hooks/settings.json a ~/.claude/settings.json sin pisar lo existente
#   (idempotente; deja backup settings.json.bak-<fecha>)
# - Crea ~/.config/grokbot-claude-code/env (modo 600) con placeholders si no existe
#
# Requiere jq. Respeta CLAUDE_CONFIG_DIR y BIN_DIR.

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
bin_dir="${BIN_DIR:-$HOME/.local/bin}"
config_dir="$HOME/.config/grokbot-claude-code"
hook_dst="$claude_dir/hooks/grokbot-notify.sh"
settings="$claude_dir/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: falta jq (apt install jq / brew install jq)" >&2
  exit 1
fi

mkdir -p "$claude_dir/hooks" "$bin_dir"
install -m 755 "$repo_dir/hooks/notify.sh" "$hook_dst"
install -m 755 "$repo_dir/local/notify-run" "$bin_dir/notify-run"
echo "hook:       $hook_dst"
echo "notify-run: $bin_dir/notify-run"

# Bloque de hooks apuntando a la ruta real del hook.
new_hooks=$(jq --arg cmd "bash \"$hook_dst\"" \
  '.hooks |= map_values(map(.hooks |= map(.command = $cmd)))' "$repo_dir/hooks/settings.json")

if [ -s "$settings" ]; then
  cp "$settings" "$settings.bak-$(date +%Y%m%d%H%M%S)"
  current=$(cat "$settings")
else
  current='{}'
fi

tmp=$(mktemp "$settings.XXXXXX")
printf '%s' "$current" | jq --argjson new "$new_hooks" '
  .hooks = (reduce ($new.hooks | to_entries[]) as $e (.hooks // {};
    .[$e.key] = ((.[$e.key] // []) as $cur |
      if any($cur[]?; any(.hooks[]?; (.command // "") | contains("grokbot-notify.sh")))
      then $cur
      else $cur + $e.value
      end)))
' >"$tmp"
mv "$tmp" "$settings"
echo "settings:   $settings (hooks agregados si faltaban)"

mkdir -p "$config_dir"
chmod 700 "$config_dir"
if [ ! -e "$config_dir/env" ]; then
  umask 077
  cat >"$config_dir/env" <<'EOF'
# grokbot-claude-code: config local. No commitear.
SLACK_NOTIFY_TOKEN=xoxb-REPLACE_ME
SLACK_NOTIFY_CHANNEL=C0123456789
EOF
  echo "config:     $config_dir/env (creado con placeholders: editalo)"
else
  echo "config:     $config_dir/env (ya existía, no se tocó)"
fi
chmod 600 "$config_dir/env"
