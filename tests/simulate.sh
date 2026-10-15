#!/usr/bin/env bash
# Simula eventos de Claude Code contra hooks/notify.sh en DRY_RUN (sin red).
# Uso: bash tests/simulate.sh   — sale ≠0 si falla algún caso.

# shellcheck disable=SC2016 # los backticks de los mensajes esperados son literales de mrkdwn
set -u

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="$repo_dir/hooks/notify.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# Entorno aislado: sin config real, estado en tmp.
export HOME="$work/home"
export NOTIFY_STATE_DIR="$work/state"
export NOTIFY_CONFIG="$work/no-config"
export SLACK_NOTIFY_CHANNEL="C0123456789"
export DRY_RUN=1
unset NOTIFY_AGENT NOTIFY_TASK NOTIFY_RUN_ID SLACK_NOTIFY_TOKEN CLAUDE_CODE_REMOTE CLAUDE_CODE_REMOTE_SESSION_ID
mkdir -p "$HOME"

# Repo de juguete con .claude-notify en la raíz.
proj="$work/proj"
mkdir -p "$proj/sub"
git -C "$proj" init -q -b feature/demo
printf 'NOTIFY_AGENT=agente-x\nNOTIFY_TASK=tarea-1\n' >"$proj/.claude-notify"

reset_state() { rm -rf "$NOTIFY_STATE_DIR"; }
run_hook() { printf '%s' "$1" | bash "$hook"; }
# text_of <salida DRY_RUN>: el campo text del payload (mensaje Slack, multilínea).
text_of() { printf '%s' "$1" | sed -n 's/^DRY_RUN POST [^ ]* //p' | jq -r .text 2>/dev/null; }
# has_line <salida DRY_RUN> <línea>: el mensaje tiene esa línea exacta.
has_line() { text_of "$1" | grep -qxF -- "$2"; }
nl=$'\n'

ev() { # ev <evento> <session> [campos extra JSON] [cwd]
  printf '{"session_id":"%s","transcript_path":"/tmp/t.jsonl","cwd":"%s","hook_event_name":"%s"%s}' \
    "$2" "${4:-$proj}" "$1" "${3:+,$3}"
}

# 1. Evento del agente principal envía, con formato correcto.
reset_state
out=$(run_hook "$(ev Stop s1 '"stop_hook_active":false,"last_assistant_message":"Listo: tests \"verdes\".\nVer STATUS.md"')")
expected='🤖 *Claude Code*
*evento:* `Stop`
*sesión:* `s1`
*rama:* `feature/demo`
*agente:* `notify-agente-x`
*tarea:* `tarea-1`'
got=$(text_of "$out")
chan=$(printf '%s' "$out" | sed -n 's/^DRY_RUN POST [^ ]* //p' | jq -r .channel 2>/dev/null)
if [ "$got" = "$expected" ] && [ "$chan" = "C0123456789" ]; then ok "Stop principal envía"; else ko "Stop principal envía" "got: $out"; fi

# 2. Evento con agent_id (subagente) se descarta.
reset_state
out=$(run_hook "$(ev Stop s2 '"agent_id":"a-123","agent_type":"Explore","last_assistant_message":"sub"')")
if [ -z "$out" ]; then ok "agent_id se descarta"; else ko "agent_id se descarta" "$out"; fi

# 3. Stop + SessionEnd en la misma sesión → un solo mensaje.
reset_state
out1=$(run_hook "$(ev Stop s3 '"last_assistant_message":"fin"')")
out2=$(run_hook "$(ev SessionEnd s3 '"reason":"other"')")
if [ -n "$out1" ] && [ -z "$out2" ]; then ok "Stop + SessionEnd → uno"; else ko "Stop + SessionEnd → uno" "stop=[$out1] end=[$out2]"; fi

# 3b. Stop repetido del mismo turno → uno; SessionEnd solo → envía.
out3=$(run_hook "$(ev Stop s3 '"last_assistant_message":"fin"')")
out4=$(run_hook "$(ev SessionEnd s3b '"reason":"other"')")
if [ -z "$out3" ] && has_line "$out4" '*evento:* `SessionEnd` · `reason=other`'; then
  ok "Stop duplicado se descarta; SessionEnd sin Stop envía"
else
  ko "Stop duplicado / SessionEnd sin Stop" "dup=[$out3] end=[$out4]"
fi

# 3c. Stop con tareas en segundo plano = pausa: no avisa y no tapa el SessionEnd (jq y sed).
for nojq in 0 1; do
  reset_state
  bg='"last_assistant_message":"corriendo","background_tasks":[{"id":"t1","type":"shell","status":"running"}],"session_crons":[]'
  out1=$(printf '%s' "$(ev Stop s3c "$bg")" | NOTIFY_NO_JQ=$nojq bash "$hook")
  out2=$(printf '%s' "$(ev Stop s3c '"last_assistant_message":"listo","background_tasks":[],"session_crons":[]')" | NOTIFY_NO_JQ=$nojq bash "$hook")
  reset_state
  printf '%s' "$(ev Stop s3d "$bg")" | NOTIFY_NO_JQ=$nojq bash "$hook" >/dev/null
  out3=$(printf '%s' "$(ev SessionEnd s3d '"reason":"other"')" | NOTIFY_NO_JQ=$nojq bash "$hook")
  if [ -z "$out1" ] && has_line "$out2" '*sesión:* `s3c`' && has_line "$out3" '*evento:* `SessionEnd` · `reason=other`'; then
    ok "Stop en pausa no avisa (NOTIFY_NO_JQ=$nojq)"
  else
    ko "Stop en pausa (NOTIFY_NO_JQ=$nojq)" "bg=[$out1] fin=[$out2] end=[$out3]"
  fi
done

# 4. Fallback sed sin jq produce el mismo payload.
reset_state
json=$(ev Stop s4 '"stop_hook_active":false,"last_assistant_message":"Hecho \"ok\" con \\\\ barra\ny salto","agent_type":null')
with_jq=$(run_hook "$json")
reset_state
without_jq=$(printf '%s' "$json" | NOTIFY_NO_JQ=1 bash "$hook")
if [ -n "$with_jq" ] && [ "$with_jq" = "$without_jq" ] &&
  printf '%s' "$without_jq" | sed 's/^DRY_RUN POST [^ ]* //' | jq -e . >/dev/null 2>&1; then
  ok "fallback sed = jq (JSON válido)"
else
  ko "fallback sed = jq" "jq=[$with_jq] sed=[$without_jq]"
fi

# 4b. Fallback sed también descarta agent_id, pero no si solo aparece dentro de un texto
#     ni si está anidado (solo cuenta el primer nivel).
reset_state
out=$(run_hook "$(ev Stop s4b '"agent_id":"x"')" 2>&1; printf '%s' "$(ev Stop s4b '"agent_id":"x"')" | NOTIFY_NO_JQ=1 bash "$hook")
txt=$(printf '%s' "$(ev Stop s4c '"last_assistant_message":"campo \"agent_id\": nada"')" | NOTIFY_NO_JQ=1 bash "$hook")
nested=""
for nojq in 0 1; do
  reset_state
  nested+=$(printf '%s' "$(ev PermissionRequest s4d '"tool_name":"Agent","tool_input":{"agent_id":"y","p":[{"agent_id":1}]}')" | NOTIFY_NO_JQ=$nojq bash "$hook")
done
if [ -z "$out" ] && [ -n "$txt" ] && [ "$(printf '%s' "$nested" | grep -o 'DRY_RUN' | wc -l)" = 2 ]; then
  ok "fallback sed: agent_id (solo primer nivel)"
else
  ko "fallback sed: agent_id" "out=[$out] txt=[$txt] nested=[$nested]"
fi

# 5. Sin agente configurado → no envía.
reset_state
noproj="$work/noproj"
mkdir -p "$noproj"
out=$(run_hook "$(ev Stop s5 '"last_assistant_message":"x"' "$noproj")")
if [ -z "$out" ]; then ok "sin agente no envía"; else ko "sin agente no envía" "$out"; fi

# 5b. Fallback a env vars.
out=$(printf '%s' "$(ev Stop s5b '"last_assistant_message":"x"' "$noproj")" | NOTIFY_AGENT=agente-env NOTIFY_TASK=t-env bash "$hook")
expected='🤖 *Claude Code*
*evento:* `Stop`
*sesión:* `s5b`
*agente:* `notify-agente-env`
*tarea:* `t-env`'
if [ "$(text_of "$out")" = "$expected" ]; then ok "fallback a NOTIFY_AGENT/NOTIFY_TASK (sin rama ni repo)"; else ko "fallback env" "$out"; fi

# 5c. .claude-notify en la raíz del repo encontrado desde un subdirectorio.
reset_state
out=$(run_hook "$(ev Stop s5c '"last_assistant_message":"x"' "$proj/sub")")
if printf '%s' "$out" | grep -q 'notify-agente-x'; then ok ".claude-notify desde subdirectorio"; else ko ".claude-notify desde subdirectorio" "$out"; fi

# 6. PermissionRequest avisa; Notification permission_prompt posterior se descarta; otros tipos pasan.
reset_state
out1=$(run_hook "$(ev PermissionRequest s6 '"tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"x"}')")
out2=$(run_hook "$(ev Notification s6 '"message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"')")
out3=$(run_hook "$(ev Notification s6 '"message":"MCP pide datos","notification_type":"elicitation_dialog"')")
if has_line "$out1" '*evento:* `PermissionRequest` · `tool=Bash`' &&
  ! printf '%s' "$out1" | grep -q 'rm -rf' && [ -z "$out2" ] && has_line "$out3" '*evento:* `Notification` · `type=elicitation_dialog`'; then
  ok "PermissionRequest + Notification dedup"
else
  ko "PermissionRequest + Notification" "pr=[$out1] np=[$out2] el=[$out3]"
fi

# 6b. PermissionRequest no publica tool_input (jq y sed): puede traer credenciales.
for nojq in 0 1; do
  reset_state
  out=$(printf '%s' "$(ev PermissionRequest s6b '"tool_name":"Bash","tool_input":{"command":"curl -H \"Authorization: Bearer xoxb-REPLACE_ME\" x","file_path":"/secreto"}')" | NOTIFY_NO_JQ=$nojq bash "$hook")
  if has_line "$out" '*evento:* `PermissionRequest` · `tool=Bash`' && ! printf '%s' "$out" | grep -Eq 'REPLACE_ME|curl|secreto'; then
    ok "PermissionRequest sin tool_input (NOTIFY_NO_JQ=$nojq)"
  else
    ko "PermissionRequest sin tool_input (NOTIFY_NO_JQ=$nojq)" "$out"
  fi
done

# 6c. Tarea y rama no pueden despertar a otro agente ni hacer ping (jq y sed).
evil="$work/evil"
mkdir -p "$evil"
git -C "$evil" init -q -b notify-rama
printf 'NOTIFY_AGENT=agente-x\nNOTIFY_TASK=notify-tarea\n' >"$evil/.claude-notify"
for nojq in 0 1; do
  reset_state
  out=$(printf '%s' "$(ev Stop s6c '"last_assistant_message":"avisale a notify-otro y NOTIFY-dev <!channel> <!here> <@U0123456789> <#C0123456789|x> a&b"' "$evil")" | NOTIFY_NO_JQ=$nojq bash "$hook")
  got=$(printf '%s' "$out" | sed -n 's/^DRY_RUN POST [^ ]* //p' | jq -r .text 2>/dev/null)
  expected='🤖 *Claude Code*
*evento:* `Stop`
*sesión:* `s6c`
*rama:* `notify‐rama`
*agente:* `notify-agente-x`
*tarea:* `notify‐tarea`'
  if [ "$got" = "$expected" ] && [ "$(printf '%s' "$got" | grep -oi 'notify-' | wc -l)" = 1 ]; then
    ok "texto libre neutralizado (NOTIFY_NO_JQ=$nojq)"
  else
    ko "texto libre neutralizado (NOTIFY_NO_JQ=$nojq)" "got: $got"
  fi
done

# 7. StopFailure lleva el tipo de error.
reset_state
out=$(run_hook "$(ev StopFailure s7 '"error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"')")
if has_line "$out" '*evento:* `StopFailure` · `error=rate_limit`' && ! printf '%s' "$out" | grep -q 'Rate limit reached'; then ok "StopFailure"; else ko "StopFailure" "$out"; fi

# 8. SessionStart apagado por defecto, prendido con NOTIFY_SESSION_START=1.
reset_state
off=$(run_hook "$(ev SessionStart s8 '"source":"startup"')")
on=$(printf '%s' "$(ev SessionStart s8 '"source":"startup"')" | NOTIFY_SESSION_START=1 bash "$hook")
if [ -z "$off" ] && has_line "$on" '*evento:* `SessionStart` · `source=startup`'; then ok "SessionStart opcional"; else ko "SessionStart opcional" "off=[$off] on=[$on]"; fi

# 9. Sin canal → no envía; sin token y sin DRY_RUN → no intenta red, solo loguea; siempre exit 0.
reset_state
out=$(printf '%s' "$(ev Stop s9 '"last_assistant_message":"x"')" | SLACK_NOTIFY_CHANNEL="" bash "$hook"); rc1=$?
out2=$(printf '%s' "$(ev Stop s9b '"last_assistant_message":"x"')" | DRY_RUN=0 bash "$hook"); rc2=$?
printf 'no es json' | bash "$hook"; rc3=$?
bash "$hook" </dev/null; rc4=$?
if [ -z "$out" ] && [ -z "$out2" ] && [ $rc1$rc2$rc3$rc4 = 0000 ] && grep -q 'sin SLACK_NOTIFY_TOKEN' "$NOTIFY_STATE_DIR/notify.log"; then
  ok "sin canal/token no envía; exit 0 con input roto"
else
  ko "sin canal/token / input roto" "rc=$rc1$rc2$rc3$rc4 out=[$out] out2=[$out2]"
fi

# 9a. Si el envío falla no queda marca de dedup: el próximo intento vuelve a avisar.
reset_state
printf '%s' "$(ev Stop s9d '"last_assistant_message":"x"')" | DRY_RUN=0 bash "$hook"
out=$(run_hook "$(ev Stop s9d '"last_assistant_message":"x"')")
if has_line "$out" '*sesión:* `s9d`'; then ok "sin marca de dedup si no se envió"; else ko "dedup tras fallo" "$out"; fi

# 9c. Estado por usuario (no /tmp compartido) y privado.
reset_state
dout=$(printf '%s' "$(ev Stop s9e '"last_assistant_message":"x"')" | env -u NOTIFY_STATE_DIR XDG_STATE_HOME="$work/xdg" bash "$hook")
if [ -n "$dout" ] && [ -f "$work/xdg/grokbot-claude-code/notify.log" ] &&
  [ "$(stat -c %a "$work/xdg/grokbot-claude-code")" = 700 ] && [ "$(stat -c %a "$work/xdg/grokbot-claude-code/notify.log")" = 600 ]; then
  ok "estado en XDG_STATE_HOME con permisos privados"
else
  ko "estado por usuario" "$(ls -laR "$work/xdg" 2>&1)"
fi

# 9b. Config con placeholder xoxb-REPLACE_ME cuenta como sin token.
reset_state
printf 'SLACK_NOTIFY_TOKEN=xoxb-REPLACE_ME\nSLACK_NOTIFY_CHANNEL=C0123456789\n' >"$work/cfg"
printf '%s' "$(ev Stop s9c '"last_assistant_message":"x"')" | NOTIFY_CONFIG="$work/cfg" DRY_RUN=0 bash "$hook"
if grep -q 'sin SLACK_NOTIFY_TOKEN' "$NOTIFY_STATE_DIR/notify.log"; then ok "placeholder de token no se usa"; else ko "placeholder de token"; fi

# 10. notify-run: comando falso que sale 137 → ProcessExit.
reset_state
fake="$work/fake-claude"
cat >"$fake" <<'EOF'
#!/usr/bin/env bash
exit 137
EOF
chmod +x "$fake"
out=$(cd "$proj" && NOTIFY_CLAUDE_BIN="$fake" NOTIFY_HOOK="$hook" bash "$repo_dir/local/notify-run" -p "hola")
rc=$?
if [ "$rc" = 137 ] && has_line "$out" '*evento:* `ProcessExit` · `exit=137`' &&
  text_of "$out" | grep -q '^\*sesión:\* `run-' && has_line "$out" '*agente:* `notify-agente-x`'; then
  ok "notify-run 137 → ProcessExit"
else
  ko "notify-run 137 → ProcessExit" "rc=$rc out=[$out]"
fi

# 10b. notify-run: si un hook (Stop) ya avisó, no publica ProcessExit; usa el session_id visto.
reset_state
fake2="$work/fake-claude-ok"
cat >"$fake2" <<EOF
#!/usr/bin/env bash
printf '%s' '$(ev Stop s10 '"last_assistant_message":"ok"')' | bash "$hook"
exit 0
EOF
chmod +x "$fake2"
out=$(cd "$proj" && NOTIFY_CLAUDE_BIN="$fake2" NOTIFY_HOOK="$hook" bash "$repo_dir/local/notify-run" -p "hola")
if [ "$(printf '%s\n' "$out" | grep -c 'DRY_RUN')" = 1 ] && has_line "$out" '*evento:* `Stop`'; then
  ok "notify-run no duplica si Stop avisó"
else
  ko "notify-run no duplica" "$out"
fi

# 10c. notify-run: hook no terminal (PermissionRequest) y luego SIGKILL → ProcessExit con el session_id real.
reset_state
fake3="$work/fake-claude-kill"
cat >"$fake3" <<EOF
#!/usr/bin/env bash
printf '%s' '$(ev PermissionRequest s10c '"tool_name":"Bash","tool_input":{"command":"ls"}')' | bash "$hook" >/dev/null
kill -KILL \$\$
EOF
chmod +x "$fake3"
out=$(cd "$proj" && NOTIFY_CLAUDE_BIN="$fake3" NOTIFY_HOOK="$hook" bash "$repo_dir/local/notify-run" 2>/dev/null)
rc=$?
if [ "$rc" = 137 ] && has_line "$out" '*evento:* `ProcessExit` · `exit=137`' && has_line "$out" '*sesión:* `s10c`'; then
  ok "notify-run SIGKILL → ProcessExit con session_id"
else
  ko "notify-run SIGKILL" "rc=$rc out=[$out]"
fi

# 11. cloud/setup.sh al día y funcional: instala hook y mergea settings sin pisar.
if bash "$repo_dir/cloud/build.sh" --check; then ok "cloud/setup.sh generado al día"; else ko "cloud/setup.sh desactualizado"; fi
chome="$work/cloud-home"
mkdir -p "$chome/.claude"
echo '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo otro"}]}]}}' >"$chome/.claude/settings.json"
HOME="$chome" CLAUDE_CONFIG_DIR="" bash "$repo_dir/cloud/setup.sh" >/dev/null 2>&1
HOME="$chome" CLAUDE_CONFIG_DIR="" bash "$repo_dir/cloud/setup.sh" >/dev/null 2>&1
s="$chome/.claude/settings.json"
if cmp -s "$chome/.claude/hooks/grokbot-notify.sh" "$hook" &&
  [ "$(jq -r .model "$s")" = x ] && [ "$(jq '.hooks.Stop | length' "$s")" = 2 ] &&
  [ "$(jq '.hooks.SessionEnd[0].hooks[0].timeout' "$s")" = 10 ] &&
  [ "$(jq -r '.hooks.Notification[0].matcher' "$s")" = 'permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog' ] &&
  [ "$(stat -c %a "$chome/.config/grokbot-claude-code/env")" = 600 ]; then
  ok "cloud/setup.sh instala y mergea (idempotente)"
else
  ko "cloud/setup.sh" "$(cat "$s")"
fi

# 12. local/install.sh: idempotente, conserva settings, config 600 con placeholders.
ihome="$work/install-home"
mkdir -p "$ihome/.claude"
echo '{"permissions":{"allow":["Bash(ls)"]}}' >"$ihome/.claude/settings.json"
HOME="$ihome" CLAUDE_CONFIG_DIR="" BIN_DIR="$ihome/bin" bash "$repo_dir/local/install.sh" >/dev/null &&
  HOME="$ihome" CLAUDE_CONFIG_DIR="" BIN_DIR="$ihome/bin" bash "$repo_dir/local/install.sh" >/dev/null
s="$ihome/.claude/settings.json"
if [ -x "$ihome/bin/notify-run" ] && [ -x "$ihome/.claude/hooks/grokbot-notify.sh" ] &&
  [ "$(jq -r '.permissions.allow[0]' "$s")" = 'Bash(ls)' ] && [ "$(jq '.hooks.Stop | length' "$s")" = 1 ] &&
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" = "bash \"$ihome/.claude/hooks/grokbot-notify.sh\"" ] &&
  [ "$(stat -c %a "$ihome/.config/grokbot-claude-code/env")" = 600 ] &&
  grep -q 'xoxb-REPLACE_ME' "$ihome/.config/grokbot-claude-code/env"; then
  ok "local/install.sh instala y mergea (idempotente)"
else
  ko "local/install.sh" "$(cat "$s" 2>/dev/null)"
fi

# 13. Formato del mensaje: pares exactos y casos borde (jq y sed deben coincidir).
fmt_repo="$work/fmt"
mkdir -p "$fmt_repo"
git -C "$fmt_repo" init -q -b feature/x
printf 'NOTIFY_AGENT=dev-fe\nNOTIFY_TASK=t\n' >"$fmt_repo/.claude-notify"
fmt() { # fmt <nojq> <evento> <session> [extra JSON] [cwd] — texto del mensaje (env extra por variables)
  reset_state
  text_of "$(printf '%s' "$(ev "$2" "$3" "${4:-}" "${5:-$fmt_repo}")" | NOTIFY_NO_JQ=$1 bash "$hook")"
}
set_remote() { git -C "$fmt_repo" remote remove origin 2>/dev/null; [ -z "${1:-}" ] || git -C "$fmt_repo" remote add origin "$1"; }

# 13a. Nube (URL de sesión) con remote https con credenciales y detalle de evento: salida exacta.
set_remote 'https://user:ghp_SECRETTOKEN@github.com/acme/app.git'
for nojq in 0 1; do
  reset_state
  got=$(printf '%s' "$(ev StopFailure s13 '"error":"rate_limit","last_assistant_message":"Se cortó por límite"' "$fmt_repo")" |
    CLAUDE_CODE_REMOTE=true CLAUDE_CODE_REMOTE_SESSION_ID=session_abc NOTIFY_NO_JQ=$nojq bash "$hook")
  got=$(text_of "$got")
  expected='🤖 *Claude Code*
*evento:* `StopFailure` · `error=rate_limit`
*sesión:* <https://claude.ai/code/session_abc|abrir>
*repo:* `acme/app`
*rama:* `feature/x`
*agente:* `notify-dev-fe`
*tarea:* `t`'
  if [ "$got" = "$expected" ] && ! printf '%s' "$got" | grep -Eq 'SECRET|ghp_|user'; then
    ok "formato exacto en la nube, sin credenciales (NOTIFY_NO_JQ=$nojq)"
  else
    ko "formato exacto en la nube (NOTIFY_NO_JQ=$nojq)" "got: $got"
  fi
done

# 13b. Remotes: https, ssh scp-like, ssh://, sin .git, sin remote, ruta local (no se muestra).
for case in 'https://github.com/o/n.git|o/n' 'git@github.com:o/n.git|o/n' 'ssh://git@host.com:2222/o/n|o/n' \
  'https://tok@gitlab.com/g/sub/n.git|sub/n' '/srv/git/local.git|' ''; do
  set_remote "${case%%|*}"
  got=$(fmt 0 Stop s13b '"last_assistant_message":"x"')
  line4=$(printf '%s' "$got" | sed -n 4p)
  want=${case#*|}
  [ "$case" = "" ] && want=""
  if [ -n "$want" ]; then pat="*repo:* \`$want\`"; else pat='*rama:* `feature/x`'; fi
  if [ "$line4" = "$pat" ] && [ "$(printf '%s\n' "$got" | grep -c '^\*repo:\*')" = "$([ -n "$want" ] && echo 1 || echo 0)" ] &&
    ! printf '%s' "$got" | grep -Eq 'tok|/srv|github.com|host.com'; then
    ok "remote '${case%%|*}' → '${want:-(omitido)}'"
  else
    ko "remote '${case%%|*}'" "got: $got"
  fi
done

# 13c. Campos vacíos: sin remote, sin tarea, sin rama (no es repo git) → esas líneas no están.
set_remote ''
nt="$work/notask"
mkdir -p "$nt"
printf 'NOTIFY_AGENT=dev-fe\n' >"$nt/.claude-notify"
for nojq in 0 1; do
  got=$(fmt $nojq SessionEnd s13c '"reason":"other"' "$nt")
  expected='🤖 *Claude Code*
*evento:* `SessionEnd` · `reason=other`
*sesión:* `s13c`
*agente:* `notify-dev-fe`'
  if [ "$got" = "$expected" ]; then ok "campos vacíos omitidos (NOTIFY_NO_JQ=$nojq)"; else ko "campos vacíos (NOTIFY_NO_JQ=$nojq)" "got: $got"; fi
done

# 13d. Contrato de parseo: título y después solo líneas `*<campo>:* <valor>`, valor en backticks
#     (evento: uno o dos, separados por " · ") o <url|abrir>. Sin resumen ni línea notify- event=… (jq y sed).
field_re='^\*(evento|sesión|repo|rama|agente|tarea):\* (`[^`]*`( · `[^`]*`)?|<https://[^|>]*\|abrir>)$'
for nojq in 0 1; do
  got=$(fmt $nojq Stop s13d '"last_assistant_message":"resumen que no debe salir"')
  if [ "$(printf '%s\n' "$got" | wc -l)" = 6 ] && [ "$(printf '%s\n' "$got" | head -n 1)" = '🤖 *Claude Code*' ] &&
    [ "$(printf '%s\n' "$got" | tail -n +2 | grep -cEv "$field_re")" = 0 ] &&
    ! printf '%s' "$got" | grep -q -e '^>' -e 'resumen que no debe salir' -e 'event=' -e '^notify-'; then
    ok "un campo por línea, sin resumen ni línea máquina (NOTIFY_NO_JQ=$nojq)"
  else
    ko "un campo por línea (NOTIFY_NO_JQ=$nojq)" "got: $got"
  fi
done

# 13f. Caracteres especiales en la rama: & < >; el texto de Claude con <!channel> y notify-otro no sale (jq y sed).
git -C "$fmt_repo" symbolic-ref HEAD 'refs/heads/x&y<z>'
for nojq in 0 1; do
  got=$(fmt $nojq Stop s13g '"last_assistant_message":"<!channel> a&b <x> notify-otro NOTIFY-dev"')
  expected='🤖 *Claude Code*
*evento:* `Stop`
*sesión:* `s13g`
*rama:* `x&amp;y&lt;z&gt;`
*agente:* `notify-dev-fe`
*tarea:* `t`'
  if [ "$got" = "$expected" ] && ! printf '%s' "$got" | grep -q '<!channel>'; then
    ok "caracteres especiales escapados y notify- neutralizado (NOTIFY_NO_JQ=$nojq)"
  else
    ko "caracteres especiales (NOTIFY_NO_JQ=$nojq)" "got: $got"
  fi
done

# 13g. Backticks en rama/tarea no rompen el code span; el payload es JSON válido (jq y sed).
git -C "$fmt_repo" symbolic-ref HEAD 'refs/heads/feat/a`b'
for nojq in 0 1; do
  reset_state
  out=$(printf '%s' "$(ev Stop s13h '"last_assistant_message":"ok"' "$fmt_repo")" | NOTIFY_NO_JQ=$nojq bash "$hook")
  if printf '%s' "$out" | sed 's/^DRY_RUN POST [^ ]* //' | jq -e .text >/dev/null 2>&1 &&
    has_line "$out" '*rama:* `feat/ab`'; then
    ok "backtick en rama no rompe el span (NOTIFY_NO_JQ=$nojq)"
  else
    ko "backtick en rama (NOTIFY_NO_JQ=$nojq)" "$out"
  fi
done
git -C "$fmt_repo" symbolic-ref HEAD refs/heads/feature/x

# 13h. format_message se puede cargar con source sin ejecutar el hook.
fm=$(bash -c 'source "$1"; format_message Stop "" s1 ag "" rama o/n' _ "$hook")
if [ "$fm" = "🤖 *Claude Code*${nl}*evento:* \`Stop\`${nl}*sesión:* \`s1\`${nl}*repo:* \`o/n\`${nl}*rama:* \`rama\`${nl}*agente:* \`notify-ag\`" ]; then
  ok "format_message testeable con source"
else
  ko "format_message con source" "$fm"
fi

# 13i. format_message: `-` y vacíos se omiten (sesión incluida); notify- y < > & en el detalle y la URL.
fm=$(bash -c 'source "$1"; format_message Stop "x=notify-a<b>" "-" ag - - ""' _ "$hook")
fm2=$(bash -c 'source "$1"; format_message Stop "" "https://claude.ai/code/a|b>c" ag t "" ""' _ "$hook")
if [ "$fm" = "🤖 *Claude Code*${nl}*evento:* \`Stop\` · \`x=notify‐a&lt;b&gt;\`${nl}*agente:* \`notify-ag\`" ] &&
  [ "$fm2" = "🤖 *Claude Code*${nl}*evento:* \`Stop\`${nl}*sesión:* <https://claude.ai/code/abc|abrir>${nl}*agente:* \`notify-ag\`${nl}*tarea:* \`t\`" ]; then
  ok "format_message omite '-' y neutraliza detalle/URL"
else
  ko "format_message omite/neutraliza" "fm=[$fm] fm2=[$fm2]"
fi

echo
echo "pasaron: $pass  fallaron: $fail"
[ "$fail" = 0 ]
