#!/usr/bin/env bash
# Simula eventos de Claude Code contra hooks/notify.sh en DRY_RUN (sin red).
# Uso: bash tests/simulate.sh   — sale ≠0 si falla algún caso.

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

ev() { # ev <evento> <session> [campos extra JSON] [cwd]
  printf '{"session_id":"%s","transcript_path":"/tmp/t.jsonl","cwd":"%s","hook_event_name":"%s"%s}' \
    "$2" "${4:-$proj}" "$1" "${3:+,$3}"
}

# 1. Evento del agente principal envía, con formato correcto.
reset_state
out=$(run_hook "$(ev Stop s1 '"stop_hook_active":false,"last_assistant_message":"Listo: tests \"verdes\".\nVer STATUS.md"')")
expected='[claude] notify-agente-x event=Stop task=tarea-1 session=s1 branch=feature/demo summary=Listo: tests "verdes". Ver STATUS.md'
got=$(printf '%s' "$out" | sed -n 's/^DRY_RUN POST [^ ]* //p' | jq -r .text 2>/dev/null)
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
if [ -z "$out3" ] && printf '%s' "$out4" | grep -q 'event=SessionEnd reason=other'; then
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
  if [ -z "$out1" ] && printf '%s' "$out2" | grep -q 'summary=listo' && printf '%s' "$out3" | grep -q 'event=SessionEnd'; then
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
if printf '%s' "$out" | grep -q 'notify-agente-env event=Stop task=t-env .*branch=-'; then ok "fallback a NOTIFY_AGENT/NOTIFY_TASK"; else ko "fallback env" "$out"; fi

# 5c. .claude-notify en la raíz del repo encontrado desde un subdirectorio.
reset_state
out=$(run_hook "$(ev Stop s5c '"last_assistant_message":"x"' "$proj/sub")")
if printf '%s' "$out" | grep -q 'notify-agente-x'; then ok ".claude-notify desde subdirectorio"; else ko ".claude-notify desde subdirectorio" "$out"; fi

# 6. PermissionRequest avisa; Notification permission_prompt posterior se descarta; otros tipos pasan.
reset_state
out1=$(run_hook "$(ev PermissionRequest s6 '"tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"x"}')")
out2=$(run_hook "$(ev Notification s6 '"message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"')")
out3=$(run_hook "$(ev Notification s6 '"message":"MCP pide datos","notification_type":"elicitation_dialog"')")
if printf '%s' "$out1" | grep -q 'event=PermissionRequest tool=Bash .*summary=Bash"' &&
  ! printf '%s' "$out1" | grep -q 'rm -rf' && [ -z "$out2" ] && printf '%s' "$out3" | grep -q 'event=Notification type=elicitation_dialog'; then
  ok "PermissionRequest + Notification dedup"
else
  ko "PermissionRequest + Notification" "pr=[$out1] np=[$out2] el=[$out3]"
fi

# 6b. PermissionRequest no publica tool_input (jq y sed): puede traer credenciales.
for nojq in 0 1; do
  reset_state
  out=$(printf '%s' "$(ev PermissionRequest s6b '"tool_name":"Bash","tool_input":{"command":"curl -H \"Authorization: Bearer xoxb-REPLACE_ME\" x","file_path":"/secreto"}')" | NOTIFY_NO_JQ=$nojq bash "$hook")
  if printf '%s' "$out" | grep -q 'tool=Bash .*summary=Bash"' && ! printf '%s' "$out" | grep -Eq 'REPLACE_ME|curl|secreto'; then
    ok "PermissionRequest sin tool_input (NOTIFY_NO_JQ=$nojq)"
  else
    ko "PermissionRequest sin tool_input (NOTIFY_NO_JQ=$nojq)" "$out"
  fi
done

# 6c. Resumen, tarea y rama no pueden despertar a otro agente ni hacer ping (jq y sed).
evil="$work/evil"
mkdir -p "$evil"
git -C "$evil" init -q -b notify-rama
printf 'NOTIFY_AGENT=agente-x\nNOTIFY_TASK=notify-tarea\n' >"$evil/.claude-notify"
for nojq in 0 1; do
  reset_state
  out=$(printf '%s' "$(ev Stop s6c '"last_assistant_message":"avisale a notify-otro y NOTIFY-dev <!channel> <!here> <@U0123456789> <#C0123456789|x> a&b"' "$evil")" | NOTIFY_NO_JQ=$nojq bash "$hook")
  got=$(printf '%s' "$out" | sed -n 's/^DRY_RUN POST [^ ]* //p' | jq -r .text 2>/dev/null)
  expected='[claude] notify-agente-x event=Stop task=notify‐tarea session=s6c branch=notify‐rama summary=avisale a notify‐otro y NOTIFY‐dev &lt;!channel&gt; &lt;!here&gt; &lt;@U0123456789&gt; &lt;#C0123456789|x&gt; a&amp;b'
  if [ "$got" = "$expected" ] && [ "$(printf '%s' "$got" | grep -oi 'notify-' | wc -l)" = 1 ]; then
    ok "texto libre neutralizado (NOTIFY_NO_JQ=$nojq)"
  else
    ko "texto libre neutralizado (NOTIFY_NO_JQ=$nojq)" "got: $got"
  fi
done

# 7. StopFailure lleva el tipo de error.
reset_state
out=$(run_hook "$(ev StopFailure s7 '"error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"')")
if printf '%s' "$out" | grep -q 'event=StopFailure error=rate_limit .*summary=API Error: Rate limit reached'; then ok "StopFailure"; else ko "StopFailure" "$out"; fi

# 8. SessionStart apagado por defecto, prendido con NOTIFY_SESSION_START=1.
reset_state
off=$(run_hook "$(ev SessionStart s8 '"source":"startup"')")
on=$(printf '%s' "$(ev SessionStart s8 '"source":"startup"')" | NOTIFY_SESSION_START=1 bash "$hook")
if [ -z "$off" ] && printf '%s' "$on" | grep -q 'event=SessionStart source=startup'; then ok "SessionStart opcional"; else ko "SessionStart opcional" "off=[$off] on=[$on]"; fi

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
if printf '%s' "$out" | grep -q 'event=Stop task=tarea-1 session=s9d '; then ok "sin marca de dedup si no se envió"; else ko "dedup tras fallo" "$out"; fi

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
if [ "$rc" = 137 ] && printf '%s' "$out" | grep -q 'notify-agente-x event=ProcessExit exit=137 task=tarea-1 session=run-'; then
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
if [ "$(printf '%s\n' "$out" | grep -c 'DRY_RUN')" = 1 ] && printf '%s' "$out" | grep -q 'event=Stop'; then
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
if [ "$rc" = 137 ] && printf '%s' "$out" | grep -q 'event=ProcessExit exit=137 task=tarea-1 session=s10c '; then
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

echo
echo "pasaron: $pass  fallaron: $fail"
[ "$fail" = 0 ]
