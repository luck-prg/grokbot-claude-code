#!/usr/bin/env bash
# Tests de los scripts sin red real ni tokens reales, con HOME temporal:
# - hooks/notify.sh hace un POST de verdad contra un servidor HTTP falso local (SLACK_API_URL).
# - local/notify-run con un claude falso.
# - local/install.sh (idempotente) y --uninstall.
# - cloud/build.sh (--check y build en una copia) y cloud/setup.sh en un HOME limpio.
# Uso: bash tests/test-scripts.sh   — sale ≠0 si falla algún caso.

set -u

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="$repo_dir/hooks/notify.sh"
work=$(mktemp -d)
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# Entorno aislado: HOME temporal, sin config real, sin proxies hacia afuera.
export HOME="$work/home"
export NOTIFY_STATE_DIR="$work/state"
export NOTIFY_CONFIG="$work/no-config"
unset NOTIFY_AGENT NOTIFY_TASK NOTIFY_RUN_ID SLACK_NOTIFY_TOKEN SLACK_NOTIFY_CHANNEL DRY_RUN \
  CLAUDE_CODE_REMOTE CLAUDE_CODE_REMOTE_SESSION_ID CLAUDE_CONFIG_DIR XDG_STATE_HOME BIN_DIR \
  http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
export no_proxy="127.0.0.1,localhost" NO_PROXY="127.0.0.1,localhost"
mkdir -p "$HOME"

# Token falso: no tiene pinta de token real (xoxb- seguido de letras) ni es el placeholder.
fake_token="xoxb-test-fake"

# --- Servidor HTTP falso -----------------------------------------------------------------
# Guarda cada request (headers + body) como una línea JSON y responde {"ok":true}.
captured="$work/captured.jsonl"
port_file="$work/port"
cat >"$work/fake_slack.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

out, port_file = sys.argv[1], sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(out, "a") as f:
            f.write(json.dumps({"path": self.path, "headers": dict(self.headers.items()), "body": body}) + "\n")
        resp = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
import os
os.rename(port_file + ".tmp", port_file)
srv.serve_forever()
PY
python3 -I "$work/fake_slack.py" "$captured" "$port_file" &
server_pid=$!
for _ in $(seq 1 50); do
  [ -s "$port_file" ] && break
  sleep 0.1
done
if [ ! -s "$port_file" ]; then
  ko "servidor HTTP falso no arrancó"
  echo
  echo "pasaron: $pass  fallaron: $fail"
  exit 1
fi
SLACK_API_URL="http://127.0.0.1:$(cat "$port_file")/api/chat.postMessage"
export SLACK_API_URL

reset_capture() { rm -f "$captured"; rm -rf "$NOTIFY_STATE_DIR"; }
n_requests() { if [ -f "$captured" ]; then wc -l <"$captured" | tr -d ' '; else echo 0; fi; }
req_text() { sed -n "${1}p" "$captured" | jq -r '.body | fromjson | .text'; }
req_channel() { sed -n "${1}p" "$captured" | jq -r '.body | fromjson | .channel'; }
req_auth() { sed -n "${1}p" "$captured" | jq -r '.headers | to_entries[] | select(.key | ascii_downcase == "authorization") | .value'; }

proj="$work/proj"
mkdir -p "$proj"
printf 'NOTIFY_AGENT=agente-x\nNOTIFY_TASK=tarea-1\n' >"$proj/.claude-notify"

# 1. notify.sh: POST real contra el servidor falso.
reset_capture
printf '{"session_id":"s1","cwd":"%s","hook_event_name":"Stop","last_assistant_message":"listo"}' "$proj" |
  SLACK_NOTIFY_TOKEN="$fake_token" SLACK_NOTIFY_CHANNEL=C0123456789 bash "$hook"
rc=$?
if [ "$rc" = 0 ] && [ "$(n_requests)" = 1 ] &&
  [ "$(req_channel 1)" = C0123456789 ] &&
  req_text 1 | tail -n 1 | grep -qx 'notify-agente-x event=Stop task=tarea-1 session=s1 branch=-' &&
  [ "$(req_text 1 | wc -l)" = 3 ] && ! req_text 1 | grep -q -e '^>' -e 'listo' &&
  [ "$(req_auth 1)" = "Bearer $fake_token" ] &&
  grep -q 'enviado: ' "$NOTIFY_STATE_DIR/notify.log"; then
  ok "notify.sh POST real: canal, 3 líneas, keyword y Authorization"
else
  ko "notify.sh POST real" "rc=$rc req=$(cat "$captured" 2>/dev/null) log=$(cat "$NOTIFY_STATE_DIR/notify.log" 2>/dev/null)"
fi

# 1b. Dedup tras envío exitoso: el mismo Stop no se publica dos veces.
printf '{"session_id":"s1","cwd":"%s","hook_event_name":"Stop","last_assistant_message":"listo"}' "$proj" |
  SLACK_NOTIFY_TOKEN="$fake_token" SLACK_NOTIFY_CHANNEL=C0123456789 bash "$hook"
if [ "$(n_requests)" = 1 ]; then ok "dedup después de un envío real"; else ko "dedup después de un envío real" "requests=$(n_requests)"; fi

# 2. notify-run: claude falso que sale 137 → ProcessExit exit=137 publicado.
reset_capture
fake="$work/fake-claude-137"
printf '#!/usr/bin/env bash\nexit 137\n' >"$fake"
chmod +x "$fake"
(cd "$proj" && NOTIFY_CLAUDE_BIN="$fake" NOTIFY_HOOK="$hook" SLACK_NOTIFY_TOKEN="$fake_token" \
  SLACK_NOTIFY_CHANNEL=C0123456789 bash "$repo_dir/local/notify-run" -p hola)
rc=$?
if [ "$rc" = 137 ] && [ "$(n_requests)" = 1 ] &&
  req_text 1 | grep -q 'notify-agente-x event=ProcessExit exit=137 task=tarea-1 '; then
  ok "notify-run exit 137 → ProcessExit publicado"
else
  ko "notify-run exit 137" "rc=$rc req=$(cat "$captured" 2>/dev/null)"
fi

# 2b. notify-run: el claude falso dispara el hook con Stop → no hay ProcessExit.
reset_capture
fake2="$work/fake-claude-stop"
cat >"$fake2" <<EOF
#!/usr/bin/env bash
printf '{"session_id":"s2","cwd":"%s","hook_event_name":"Stop","last_assistant_message":"ok"}' "$proj" | bash "$hook"
exit 0
EOF
chmod +x "$fake2"
(cd "$proj" && NOTIFY_CLAUDE_BIN="$fake2" NOTIFY_HOOK="$hook" SLACK_NOTIFY_TOKEN="$fake_token" \
  SLACK_NOTIFY_CHANNEL=C0123456789 bash "$repo_dir/local/notify-run" -p hola)
rc=$?
if [ "$rc" = 0 ] && [ "$(n_requests)" = 1 ] && req_text 1 | grep -q 'event=Stop ' &&
  ! grep -q ProcessExit "$captured"; then
  ok "notify-run con Stop → sin ProcessExit"
else
  ko "notify-run con Stop" "rc=$rc req=$(cat "$captured" 2>/dev/null)"
fi

# 3. local/install.sh en un HOME temporal: idempotente, conserva settings, env 600.
ihome="$work/install-home"
mkdir -p "$ihome/.claude"
echo '{"model":"x","permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo otro"}]}]}}' \
  >"$ihome/.claude/settings.json"
inst() { HOME="$ihome" BIN_DIR="$ihome/bin" bash "$repo_dir/local/install.sh" "$@"; }
inst >/dev/null && inst >/dev/null
rc=$?
s="$ihome/.claude/settings.json"
hook_cmd="bash \"$ihome/.claude/hooks/grokbot-notify.sh\""
if [ "$rc" = 0 ] && [ -x "$ihome/.claude/hooks/grokbot-notify.sh" ] && [ -x "$ihome/bin/notify-run" ] &&
  [ "$(jq -r .model "$s")" = x ] && [ "$(jq -r '.permissions.allow[0]' "$s")" = 'Bash(ls)' ] &&
  [ "$(jq --arg c "$hook_cmd" '[.hooks.Stop[].hooks[] | select(.command == $c)] | length' "$s")" = 1 ] &&
  [ "$(jq '.hooks.Stop | length' "$s")" = 2 ] &&
  [ "$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$s")" = "$hook_cmd" ] &&
  [ "$(stat -c %a "$ihome/.config/grokbot-claude-code/env")" = 600 ]; then
  ok "local/install.sh idempotente (un solo Stop propio, settings conservados, env 600)"
else
  ko "local/install.sh" "rc=$rc $(cat "$s" 2>/dev/null)"
fi

# 3b. --uninstall: borra hook, notify-run y entradas; conserva el resto y el env.
out=$(inst --uninstall)
rc=$?
if [ "$rc" = 0 ] && [ ! -e "$ihome/.claude/hooks/grokbot-notify.sh" ] && [ ! -e "$ihome/bin/notify-run" ] &&
  ! grep -q grokbot-notify.sh "$s" &&
  [ "$(jq -r .model "$s")" = x ] && [ "$(jq -r '.permissions.allow[0]' "$s")" = 'Bash(ls)' ] &&
  [ "$(jq -c '.hooks' "$s")" = '{"Stop":[{"hooks":[{"type":"command","command":"echo otro"}]}]}' ] &&
  [ -f "$ihome/.config/grokbot-claude-code/env" ] && printf '%s' "$out" | grep -q 'se dejó'; then
  ok "local/install.sh --uninstall"
else
  ko "local/install.sh --uninstall" "rc=$rc out=[$out] $(cat "$s" 2>/dev/null)"
fi

# 3c. --uninstall sin otros hooks deja settings sin la clave hooks; flag desconocido → 2.
uhome="$work/uninstall-home"
mkdir -p "$uhome"
HOME="$uhome" BIN_DIR="$uhome/bin" bash "$repo_dir/local/install.sh" >/dev/null &&
  HOME="$uhome" BIN_DIR="$uhome/bin" bash "$repo_dir/local/install.sh" --uninstall >/dev/null
HOME="$uhome" BIN_DIR="$uhome/bin" bash "$repo_dir/local/install.sh" --nope >/dev/null 2>&1
rc=$?
if [ "$(jq -c . "$uhome/.claude/settings.json")" = '{}' ] && [ "$rc" = 2 ]; then
  ok "--uninstall borra eventos vacíos; flag desconocido → 2"
else
  ko "--uninstall eventos vacíos / flag" "rc=$rc $(cat "$uhome/.claude/settings.json" 2>/dev/null)"
fi

# 4. cloud/build.sh: --check pasa y el render coincide con el commiteado.
if bash "$repo_dir/cloud/build.sh" --check; then ok "cloud/build.sh --check"; else ko "cloud/build.sh --check"; fi
copy="$work/repo-copy"
mkdir -p "$copy/cloud" "$copy/hooks"
cp "$repo_dir/cloud/build.sh" "$copy/cloud/"
cp "$repo_dir/hooks/notify.sh" "$repo_dir/hooks/settings.json" "$copy/hooks/"
if bash "$copy/cloud/build.sh" >/dev/null && diff -q "$copy/cloud/setup.sh" "$repo_dir/cloud/setup.sh" >/dev/null; then
  ok "build en una copia = cloud/setup.sh commiteado"
else
  ko "build en una copia difiere de cloud/setup.sh" "$(diff "$copy/cloud/setup.sh" "$repo_dir/cloud/setup.sh" | head -n 20)"
fi

# 5. cloud/setup.sh en un HOME limpio: hook + settings, idempotente.
chome="$work/cloud-home"
mkdir -p "$chome"
HOME="$chome" SLACK_NOTIFY_CHANNEL=C0123456789 bash "$repo_dir/cloud/setup.sh" >/dev/null 2>&1
rc1=$?
cs="$chome/.claude/settings.json"
first=$(cat "$cs" 2>/dev/null)
HOME="$chome" SLACK_NOTIFY_CHANNEL=C0123456789 bash "$repo_dir/cloud/setup.sh" >/dev/null 2>&1
rc2=$?
if [ "$rc1$rc2" = 00 ] && cmp -s "$chome/.claude/hooks/grokbot-notify.sh" "$hook" &&
  [ -x "$chome/.claude/hooks/grokbot-notify.sh" ] &&
  [ "$(jq '[.hooks[][].hooks[] | select(.command | contains("grokbot-notify.sh"))] | length' "$cs")" = 5 ] &&
  [ "$(jq '.hooks.Stop | length' "$cs")" = 1 ] &&
  [ "$(cat "$cs")" = "$first" ] &&
  grep -qx 'SLACK_NOTIFY_CHANNEL=C0123456789' "$chome/.config/grokbot-claude-code/env" &&
  [ "$(stat -c %a "$chome/.config/grokbot-claude-code/env")" = 600 ]; then
  ok "cloud/setup.sh en HOME limpio (idempotente)"
else
  ko "cloud/setup.sh en HOME limpio" "rc=$rc1$rc2 $(cat "$cs" 2>/dev/null)"
fi

echo
echo "pasaron: $pass  fallaron: $fail"
[ "$fail" = 0 ]
