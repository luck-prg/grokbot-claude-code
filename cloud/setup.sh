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
#   - Variables de entorno: SLACK_NOTIFY_CHANNEL=C0123456789 (id del canal) y,
#     si el environment es de un solo agente, NOTIFY_AGENT=<slug>.
#
# Nunca hace fallar el setup: si algo sale mal, lo dice y sigue.

set -u

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
hook="$claude_dir/hooks/grokbot-notify.sh"
mkdir -p "$claude_dir/hooks"

cat >"$hook" <<'GROKBOT_NOTIFY_SH_EOF'
#!/usr/bin/env bash
# grokbot-claude-code: hook de Claude Code que avisa en Slack a un agente de Grok Bot.
#
# Lee el JSON del hook por stdin y publica en el canal de notificaciones un mensaje
# Slack mrkdwn con un campo por línea (ver format_message):
#   *Claude Code*
#   • *evento:* `Stop`
#   • *sesión:* <url|session_xxx>
#   • *repo:* `owner/name`
#   • *rama:* `x`
#   • *agente:* `notify-<agente>`
#   • *tarea:* `t`
#
# Nunca bloquea ni hace fallar a Claude: siempre sale con 0 y no escribe JSON en stdout.
#
# Variables (env o ~/.config/grokbot-claude-code/env):
#   SLACK_NOTIFY_TOKEN    token xoxb- del bot (en la nube puede faltar: lo inyecta el proxy)
#   SLACK_NOTIFY_CHANNEL  id del canal (#<canal>), p.ej. C0123456789
#   SLACK_NOTIFY_USERNAME nombre con el que se publica (default "Claude Code")
#   SLACK_NOTIFY_ICON_URL ícono con el que se publica (default el de la app de Claude)
#                         Los dos necesitan el scope chat:write.customize; sin él Slack los ignora.
#   NOTIFY_AGENT / NOTIFY_TASK  fallback si no hay archivo .claude-notify
#   NOTIFY_SESSION_START=1      también avisa en SessionStart (apagado por defecto)
#   DRY_RUN=1             imprime el payload en vez de mandarlo
#   NOTIFY_NO_JQ=1        fuerza el parseo sin jq (para tests; jq es casi obligatorio)
#   NOTIFY_STATE_DIR      dir de estado (dedup + notify.log), privado del usuario
#                         (default ${XDG_STATE_HOME:-$HOME/.local/state}/grokbot-claude-code)
#   NOTIFY_CONFIG         ruta alternativa del archivo de config
#   NOTIFY_RUN_ID         lo pone local/notify-run para saber si algún hook ya avisó
#   SLACK_API_URL         endpoint de chat.postMessage; perilla para tests (p.ej. apuntar
#                         a un servidor falso local, ver tests/test-scripts.sh). No tocar en uso real.

SLACK_API_URL="${SLACK_API_URL:-https://slack.com/api/chat.postMessage}"
DEFAULT_USERNAME="Claude Code"
DEFAULT_ICON_URL="https://claude.ai/images/claude_app_icon.png"

# Estado y log por usuario, nunca en un /tmp compartido.
umask 077
STATE_DIR="${NOTIFY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/grokbot-claude-code}"
LOG_FILE="$STATE_DIR/notify.log"

log() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

have_jq() {
  [ "${NOTIFY_NO_JQ:-0}" != "1" ] && command -v jq >/dev/null 2>&1
}

# json_get <clave>: valor de primer nivel (string o escalar) del JSON en $INPUT.
json_get() {
  if have_jq; then
    printf '%s' "$INPUT" | jq -r --arg k "$1" \
      '.[$k] // empty | if type == "string" then . else tostring end' 2>/dev/null
    return 0
  fi
  local flat str
  flat=$(printf '%s' "$INPUT" | tr '\n\r' '  ')
  str=$(printf '%s' "$flat" |
    sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
  if [ -n "$str" ]; then
    printf '%s' "$str" | sed -e 's/\\n/ /g' -e 's/\\t/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
    return 0
  fi
  # Escalares (números, true/false).
  printf '%s' "$flat" |
    sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*([-0-9.]+|true|false).*/\1/p'
}

# json_nonempty_array <clave>: la clave de primer nivel es un array con elementos.
json_nonempty_array() {
  if have_jq; then
    printf '%s' "$INPUT" | jq -e --arg k "$1" '(.[$k] | type) == "array" and (.[$k] | length) > 0' >/dev/null 2>&1
    return $?
  fi
  printf '%s' "$INPUT" | tr '\n\r' '  ' | grep -Eq '"'"$1"'"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]'
}

# json_has <clave>: la clave existe en el primer nivel.
json_has() {
  if have_jq; then
    printf '%s' "$INPUT" | jq -e --arg k "$1" 'has($k)' >/dev/null 2>&1
    return $?
  fi
  # Recorre el JSON salteando strings y solo acepta claves de profundidad 1
  # (un agent_id anidado, p.ej. dentro de tool_input, no cuenta).
  printf '%s' "$INPUT" | awk -v key="$1" '
    BEGIN { RS = "\001" }
    {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (ins) {
          if (esc) { esc = 0 } else if (c == "\\") { esc = 1 } else if (c == "\"") {
            ins = 0
            iskey = (depth == 1); last = substr($0, start, i - start)
          }
          continue
        }
        if (c == "\"") { ins = 1; start = i + 1; continue }
        if (c == ":" && iskey && last == key) { found = 1; exit }
        if (c !~ /[ \t\r\n]/) iskey = 0
        if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") depth--
      }
    }
    END { exit(found ? 0 : 1) }'
}

json_escape() {
  if have_jq; then
    printf '%s' "$1" | jq -Rs . 2>/dev/null
    return 0
  fi
  # Los saltos de línea se conservan como \n (el mensaje es multilínea); otros controles se descartan.
  printf '"%s"' "$(printf '%s' "$1" | tr '\t\r' '  ' | tr -d '\000-\010\013\014\016-\037' |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
    awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
}

# oneline <texto> <max>: una línea, sin espacios repetidos, recortada a <max> caracteres + "…".
# El recorte cuenta caracteres UTF-8, no bytes, y nunca parte un carácter multibyte.
oneline() {
  local s max="$2" l probe="é"
  s=$(printf '%s' "$1" | tr '\n\r\t' '   ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')
  for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    ( LC_ALL=$l; [ "${#probe}" = 1 ] ) 2>/dev/null || continue
    (
      LC_ALL=$l
      if [ "${#s}" -gt "$max" ]; then printf '%s…' "${s:0:$max}"; else printf '%s' "$s"; fi
    )
    return 0
  done
  # Sin locale UTF-8: se corta por bytes y iconv descarta el multibyte partido.
  if [ "${#s}" -gt "$max" ]; then
    s="$(printf '%s' "${s:0:$max}" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)…"
  fi
  printf '%s' "$s"
}

# Texto libre (tarea, rama): que no despierte a otro agente ni haga ping.
# notify- → notify‐ (U+2010) y & < > escapados como pide Slack (<!channel>, <@U…>, <#C…>).
neutralize() {
  printf '%s' "$1" | sed -e 's/\([Nn][Oo][Tt][Ii][Ff][Yy]\)-/\1‐/g' \
    -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# code_span <texto>: `texto` para Slack, neutralizado y sin backticks que rompan el span.
code_span() {
  # shellcheck disable=SC2016 # los backticks son literales de mrkdwn
  printf '`%s`' "$(neutralize "$(printf '%s' "$1" | tr -d '`')")"
}

# repo_slug <url>: owner/name de un remote git (https, ssh://, scp-like git@host:o/n.git).
# Descarta credenciales (user:token@) y el host; vacío si no es un remote de red.
repo_slug() {
  local u="$1" path
  case "$u" in
    *://*)
      case "$u" in file://*) return 0 ;; esac
      u="${u#*://}"
      u=$(printf '%s' "$u" | sed -E 's#^[^/]*@##') # userinfo (el último @ del authority)
      path="${u#*/}"
      [ "$path" != "$u" ] || return 0
      ;;
    *:*)
      case "$u" in /* | ./* | ../*) return 0 ;; esac
      u=$(printf '%s' "$u" | sed -E 's#^[^/:]*@##') # git@host:o/n
      path="${u#*:}"
      ;;
    *) return 0 ;;
  esac
  path=$(printf '%s' "$path" | sed -E -e 's#[?\#].*$##' -e 's#/+$##' -e 's#\.git$##')
  # Últimos dos componentes (owner/name), incluso con subgrupos de GitLab.
  printf '%s' "$path" | awk -F/ 'NF >= 2 { print $(NF-1) "/" $NF }'
}

# format_message <evento> <detalle> <sesión> <agente> <tarea> <rama> <repo>
# Arma el texto Slack mrkdwn (el campo "text" del POST). Sin LLM, determinístico.
# Un campo por línea, `• *<campo>:* <valor>`, con el valor en `código` o como <url|id>:
#   *Claude Code*
#   • *evento:* `StopFailure` · `error=rate_limit`
#   • *sesión:* <https://claude.ai/code/session_abc|session_abc>   (en local: `<session_id>`)
#   • *repo:* `o/n`
#   • *rama:* `x`
#   • *agente:* `notify-slug`
#   • *tarea:* `t`
# Los campos vacíos (o `-`) se omiten con su línea. El único notify-<slug> real es el
# del agente; el texto variable se neutraliza.
format_message() {
  local event="$1" detail="$2" session="$3" agent="$4" task="$5" branch="$6" repo="$7"
  local nl=$'\n' b='• ' out url id f name val

  out="*Claude Code*"
  [ -n "$event" ] && out+="$nl$b*evento:* $(code_span "$event")${detail:+ · $(code_span "$detail")}"
  case "$session" in
    '' | '-') ;;
    https://*)
      # El texto del link es el id de sesión (el último segmento de la URL).
      url=$(printf '%s' "$session" | tr -d '<>| `')
      id="${url%/}" id="${id##*/}"
      out+="$nl$b*sesión:* <$url|$(printf '%s' "${id:-$url}" | sed 's/&/\&amp;/g')>"
      ;;
    *) out+="$nl$b*sesión:* $(code_span "$session")" ;;
  esac

  for f in "repo|$repo" "rama|$branch" "agente|$agent" "tarea|$task"; do
    name="${f%%|*}" val="${f#*|}"
    case "$val" in '' | '-') continue ;; esac
    if [ "$name" = agente ]; then
      # Literal: es el keyword que matchea la routine (el slug ya viene saneado).
      out+="$nl$b*agente:* \`notify-$val\`"
    else
      out+="$nl$b*$name:* $(code_span "$val")"
    fi
  done
  printf '%s' "$out"
}

slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-' | sed -e 's/^-*//' -e 's/-*$//'
}

load_config() {
  local cfg="${NOTIFY_CONFIG:-$HOME/.config/grokbot-claude-code/env}"
  [ -r "$cfg" ] || return 0
  # El env del proceso gana sobre el archivo.
  local tok="${SLACK_NOTIFY_TOKEN-}" chan="${SLACK_NOTIFY_CHANNEL-}"
  local user="${SLACK_NOTIFY_USERNAME-}" icon="${SLACK_NOTIFY_ICON_URL-}"
  # shellcheck disable=SC1090
  . "$cfg" 2>/dev/null || true
  [ -n "$tok" ] && SLACK_NOTIFY_TOKEN="$tok"
  [ -n "$chan" ] && SLACK_NOTIFY_CHANNEL="$chan"
  [ -n "$user" ] && SLACK_NOTIFY_USERNAME="$user"
  [ -n "$icon" ] && SLACK_NOTIFY_ICON_URL="$icon"
  # Placeholders del instalador = sin configurar.
  case "${SLACK_NOTIFY_TOKEN:-}" in *REPLACE_ME*) SLACK_NOTIFY_TOKEN="" ;; esac
  return 0
}

# read_notify_file <archivo> <clave>: lee KEY=valor sin ejecutar el archivo.
read_notify_file() {
  [ -r "$1" ] || return 0
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?'"$2"'=["'"'"']?([^"'"'"']*)["'"'"']?[[:space:]]*$/\2/p' "$1" | tail -n 1
}

resolve_target() {
  local dir="$1" root file
  AGENT="" TASK=""
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || root=""
  for file in "$dir/.claude-notify" ${root:+"$root/.claude-notify"}; do
    if [ -r "$file" ]; then
      AGENT=$(read_notify_file "$file" NOTIFY_AGENT)
      TASK=$(read_notify_file "$file" NOTIFY_TASK)
      break
    fi
  done
  [ -n "$AGENT" ] || AGENT="${NOTIFY_AGENT:-}"
  [ -n "$TASK" ] || TASK="${NOTIFY_TASK:-}"
  AGENT=$(slug "$AGENT")
  TASK=$(slug "$TASK")
  [ -n "$TASK" ] || TASK="-"
}

marker() { printf '%s/%s/%s' "$STATE_DIR" "$(slug "$SESSION_ID")" "$1"; }
mark() { mkdir -p "$(dirname "$(marker "$1")")" 2>/dev/null && date +%s >"$(marker "$1")" 2>/dev/null; }
marked() { [ -e "$(marker "$1")" ]; }
marked_within() {
  local f t now
  f=$(marker "$1")
  [ -r "$f" ] || return 1
  t=$(cat "$f" 2>/dev/null)
  now=$(date +%s)
  [ -n "$t" ] && [ $((now - t)) -le "$2" ]
}

# send <texto>: 0 si se publicó (o DRY_RUN), 1 si no.
send() {
  local text="$1" payload resp
  # Peor caso ≈ 2×4 s + 1 s: entra en el timeout de 10 s de SessionEnd.
  local curl_opts=(-sS --connect-timeout 3 --max-time 4 --retry 1 --retry-delay 1)
  # username/icon_url requieren el scope chat:write.customize; sin él Slack los ignora sin error.
  payload=$(printf '{"channel":%s,"text":%s,"username":%s,"icon_url":%s}' \
    "$(json_escape "$SLACK_NOTIFY_CHANNEL")" "$(json_escape "$text")" \
    "$(json_escape "${SLACK_NOTIFY_USERNAME:-$DEFAULT_USERNAME}")" \
    "$(json_escape "${SLACK_NOTIFY_ICON_URL:-$DEFAULT_ICON_URL}")")
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY_RUN POST %s %s\n' "$SLACK_API_URL" "$payload"
    log "dry-run: $text"
    return 0
  fi
  if [ -n "${SLACK_NOTIFY_TOKEN:-}" ]; then
    # El token va por un fd, no por la línea de comandos (no aparece en ps).
    resp=$(printf '%s' "$payload" | curl "${curl_opts[@]}" -X POST "$SLACK_API_URL" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -H @<(printf 'Authorization: Bearer %s\n' "$SLACK_NOTIFY_TOKEN") \
      --data-binary @- 2>&1)
  elif [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    # Nube: el proxy de Anthropic inyecta el header Authorization para slack.com.
    resp=$(printf '%s' "$payload" | curl "${curl_opts[@]}" -X POST "$SLACK_API_URL" \
      -H 'Content-Type: application/json; charset=utf-8' \
      --data-binary @- 2>&1)
  else
    log "sin SLACK_NOTIFY_TOKEN; no se envía: $text"
    return 1
  fi
  case "$resp" in
    *'"ok":true'*) log "enviado: $text" ;;
    *)
      log "fallo al enviar ($(oneline "$resp" 200)): $text"
      return 1
      ;;
  esac
  return 0
}

main() {
  INPUT=$(cat 2>/dev/null) || INPUT=""
  [ -n "$INPUT" ] || return 0

  local event
  event=$(json_get hook_event_name)
  [ -n "$event" ] || return 0

  # Subagentes y teammates traen agent_id; el agente principal no.
  if json_has agent_id; then
    return 0
  fi

  SESSION_ID=$(json_get session_id)
  [ -n "$SESSION_ID" ] || SESSION_ID="unknown"
  local cwd prompt_id turn
  cwd=$(json_get cwd)
  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    cwd="$PWD"
  fi
  prompt_id=$(json_get prompt_id)
  turn=$(slug "${prompt_id:-noprompt}")

  if [ -n "${NOTIFY_RUN_ID:-}" ] && [ "$event" != "ProcessExit" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null &&
      printf '%s\n' "$SESSION_ID" >"$STATE_DIR/run-$(slug "$NOTIFY_RUN_ID").session" 2>/dev/null
  fi

  resolve_target "$cwd"
  if [ -z "$AGENT" ]; then
    return 0
  fi

  local detail="" terminal=0 key="$event"
  case "$event" in
    Stop)
      terminal=1
      key="Stop-$turn"
      marked "$key" && return 0
      # Con tareas en segundo plano o crons la sesión está en pausa, no terminada:
      # el aviso llega con el Stop final, SessionEnd o el ProcessExit de notify-run.
      if json_nonempty_array background_tasks || json_nonempty_array session_crons; then
        log "Stop en pausa (tareas en segundo plano/crons), no se avisa: $SESSION_ID"
        return 0
      fi
      ;;
    StopFailure)
      terminal=1
      key="StopFailure-$turn"
      marked "$key" && return 0
      detail="error=$(slug "$(json_get error)")"
      ;;
    SessionEnd)
      terminal=1
      # Si el turno ya avisó (Stop/StopFailure), SessionEnd sobra.
      if marked SessionEnd || compgen -G "$(marker 'Stop*')" >/dev/null; then
        return 0
      fi
      detail="reason=$(slug "$(json_get reason)")"
      ;;
    Notification)
      local ntype
      ntype=$(slug "$(json_get notification_type)")
      case "$ntype" in
        permission_prompt)
          # PermissionRequest ya avisó al instante.
          marked_within PermissionRequest 120 && return 0
          ;;
        idle_prompt)
          marked "Stop-$turn" && return 0
          ;;
      esac
      key="Notification-$ntype-$turn"
      marked "$key" && return 0
      detail="type=$ntype"
      ;;
    PermissionRequest)
      # Solo el nombre de la tool: tool_input (p.ej. el comando) puede traer credenciales.
      detail="tool=$(slug "$(json_get tool_name)")"
      ;;
    SessionStart)
      [ "${NOTIFY_SESSION_START:-0}" = "1" ] || return 0
      marked SessionStart && return 0
      detail="source=$(slug "$(json_get source)")"
      ;;
    ProcessExit)
      # Lo genera local/notify-run cuando ningún hook avisó (SIGKILL, OOM, crash).
      terminal=1
      detail="exit=$(slug "$(json_get exit_code)")"
      ;;
    *)
      return 0
      ;;
  esac

  load_config
  if [ -z "${SLACK_NOTIFY_CHANNEL:-}" ]; then
    log "sin SLACK_NOTIFY_CHANNEL; no se envía ($event)"
    return 0
  fi

  local session="$SESSION_ID" branch text repo
  if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ -n "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" ]; then
    session="https://claude.ai/code/$(slug "$CLAUDE_CODE_REMOTE_SESSION_ID")"
  fi
  branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null ||
    git -C "$cwd" rev-parse --short HEAD 2>/dev/null) || branch="-"
  [ -n "$branch" ] || branch="-"
  repo=$(repo_slug "$(git -C "$cwd" remote get-url origin 2>/dev/null)")

  text=$(format_message "$event" "$detail" "$session" "$AGENT" "$TASK" "$branch" "$repo")

  # Las marcas de dedup van después de un envío exitoso: si falla, el próximo evento reintenta.
  send "$text" || return 0
  mark "$key"
  if [ "$terminal" = "1" ] && [ -n "${NOTIFY_RUN_ID:-}" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null && : >"$STATE_DIR/run-$(slug "$NOTIFY_RUN_ID").notified" 2>/dev/null
  fi
}

# Con `source` solo define las funciones (los tests llaman a format_message).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@" || true
  exit 0
fi
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
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"$HOME/.claude/hooks/grokbot-notify.sh\"", "timeout": 15 }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"$HOME/.claude/hooks/grokbot-notify.sh\"", "timeout": 15 }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog",
        "hooks": [
          { "type": "command", "command": "bash \"$HOME/.claude/hooks/grokbot-notify.sh\"", "timeout": 15 }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"$HOME/.claude/hooks/grokbot-notify.sh\"", "timeout": 15 }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"$HOME/.claude/hooks/grokbot-notify.sh\"", "timeout": 10 }
        ]
      }
    ]
  }
}
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
