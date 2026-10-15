#!/usr/bin/env bash
# Tests de cómo hooks/notify.sh decide a quién avisar y la tarea, en DRY_RUN (sin red):
# - agente desde la línea `notify: <slug>` del primer mensaje del usuario del transcript
#   (fixtures en tests/fixtures/: content string, content array, sin línea, línea en un
#   mensaje posterior), con jq y con NOTIFY_NO_JQ=1;
# - fallbacks: NOTIFY_AGENT del entorno y `desconocido` sin keyword;
# - tarea = rama sin prefijo feature/, hotfix/ o release/; sin rama no hay tarea.
# Uso: bash tests/test-transcript-agent.sh   — sale ≠0 si falla algún caso.

# shellcheck disable=SC2016 # los backticks de los mensajes esperados son literales de mrkdwn
set -u

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="$repo_dir/hooks/notify.sh"
fixtures="$repo_dir/tests/fixtures"
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
unset NOTIFY_AGENT NOTIFY_RUN_ID SLACK_NOTIFY_TOKEN CLAUDE_CODE_REMOTE CLAUDE_CODE_REMOTE_SESSION_ID
mkdir -p "$HOME"

proj="$work/proj"
mkdir -p "$proj"
git -C "$proj" init -q -b feature/login

# hook_text <nojq> <session> <transcript> [cwd]: texto del mensaje de un Stop (estado limpio).
hook_text() {
  rm -rf "$NOTIFY_STATE_DIR"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop"}' \
    "$2" "$3" "${4:-$proj}" | NOTIFY_NO_JQ=$1 bash "$hook" |
    sed -n 's/^DRY_RUN POST [^ ]* //p' | jq -r .text 2>/dev/null
}
agent_line() { printf '%s\n' "$1" | grep '^• \*agente:\*'; }
n_keywords() { printf '%s' "$1" | grep -oi 'notify-' | wc -l | tr -d ' '; }

for nojq in 0 1; do
  sfx="(NOTIFY_NO_JQ=$nojq)"

  # 1. content string: el primer mensaje real (no meta) trae la línea; los posteriores no cuentan.
  got=$(hook_text $nojq s1 "$fixtures/transcript-string.jsonl")
  expected='*Claude Code*
• *evento:* `Stop`
• *sesión:* `s1`
• *rama:* `feature/login`
• *agente:* `notify-agente-string`
• *tarea:* `login`'
  if [ "$got" = "$expected" ]; then ok "content string → agente $sfx"; else ko "content string $sfx" "got: $got"; fi

  # 2. content array: se saltean sidechain y tool_result; se juntan los bloques text.
  got=$(hook_text $nojq s2 "$fixtures/transcript-array.jsonl")
  if [ "$(agent_line "$got")" = '• *agente:* `notify-agente-array`' ] && [ "$(n_keywords "$got")" = 1 ]; then
    ok "content array → agente $sfx"
  else
    ko "content array $sfx" "got: $got"
  fi

  # 3. Sin línea válida en el primer mensaje → igual avisa, agente desconocido, sin keyword.
  for fx in transcript-missing.jsonl transcript-later.jsonl no-existe.jsonl; do
    got=$(hook_text $nojq s3 "$fixtures/$fx")
    if [ "$(agent_line "$got")" = '• *agente:* `desconocido`' ] && [ "$(n_keywords "$got")" = 0 ] &&
      printf '%s\n' "$got" | grep -qxF '• *tarea:* `login`'; then
      ok "$fx → agente desconocido sin notify- $sfx"
    else
      ko "$fx → desconocido $sfx" "got: $got"
    fi
  done

  # 3b. Sin transcript_path en el JSON → desconocido.
  rm -rf "$NOTIFY_STATE_DIR"
  got=$(printf '{"session_id":"s3b","cwd":"%s","hook_event_name":"Stop"}' "$proj" | NOTIFY_NO_JQ=$nojq bash "$hook" |
    sed -n 's/^DRY_RUN POST [^ ]* //p' | jq -r .text 2>/dev/null)
  if [ "$(agent_line "$got")" = '• *agente:* `desconocido`' ]; then ok "sin transcript_path → desconocido $sfx"; else ko "sin transcript_path $sfx" "got: $got"; fi

  # 4. Dos transcripts en la misma rama → agentes distintos.
  a=$(agent_line "$(hook_text $nojq s4a "$fixtures/transcript-string.jsonl")")
  b=$(agent_line "$(hook_text $nojq s4b "$fixtures/transcript-array.jsonl")")
  if [ "$a" = '• *agente:* `notify-agente-string`' ] && [ "$b" = '• *agente:* `notify-agente-array`' ]; then
    ok "misma rama, dos transcripts → dos agentes $sfx"
  else
    ko "misma rama, dos transcripts $sfx" "a=[$a] b=[$b]"
  fi

  # 5. Fallback: el transcript gana; si no trae la línea, NOTIFY_AGENT.
  t=$(NOTIFY_AGENT=agente-env hook_text $nojq s5 "$fixtures/transcript-string.jsonl")
  e=$(NOTIFY_AGENT=agente-env hook_text $nojq s5 "$fixtures/transcript-missing.jsonl")
  l=$(NOTIFY_AGENT=agente-env hook_text $nojq s5 "$fixtures/transcript-later.jsonl")
  if [ "$(agent_line "$t")" = '• *agente:* `notify-agente-string`' ] &&
    [ "$(agent_line "$e")" = '• *agente:* `notify-agente-env`' ] &&
    [ "$(agent_line "$l")" = '• *agente:* `notify-agente-env`' ]; then
    ok "orden transcript > NOTIFY_AGENT $sfx"
  else
    ko "orden de fallback $sfx" "t=[$t] e=[$e] l=[$l]"
  fi

  # 6. Tarea desde la rama.
  for case in 'feature/x|x' 'hotfix/arreglo-1|arreglo-1' 'release/2.0|2.0' 'main|main' 'fix/y|fix/y' 'feature/a/b|a/b'; do
    git -C "$proj" symbolic-ref HEAD "refs/heads/${case%%|*}"
    got=$(hook_text $nojq s6 "$fixtures/transcript-string.jsonl")
    if printf '%s\n' "$got" | grep -qxF "• *tarea:* \`${case#*|}\`" &&
      printf '%s\n' "$got" | grep -qxF "• *rama:* \`${case%%|*}\`"; then
      ok "rama ${case%%|*} → tarea ${case#*|} $sfx"
    else
      ko "rama ${case%%|*} → tarea $sfx" "got: $got"
    fi
  done
  git -C "$proj" symbolic-ref HEAD refs/heads/feature/login
done

# 7. HEAD detached: se muestra el commit como rama y no hay tarea.
git -C "$proj" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$proj" checkout -q --detach
sha=$(git -C "$proj" rev-parse --short HEAD)
for nojq in 0 1; do
  got=$(hook_text $nojq s7 "$fixtures/transcript-string.jsonl")
  if printf '%s\n' "$got" | grep -qxF "• *rama:* \`$sha\`" && ! printf '%s' "$got" | grep -q 'tarea'; then
    ok "HEAD detached → sin tarea (NOTIFY_NO_JQ=$nojq)"
  else
    ko "HEAD detached (NOTIFY_NO_JQ=$nojq)" "got: $got"
  fi
done
git -C "$proj" checkout -q feature/login

# 8. Fuera de un repo git: ni rama ni tarea, igual avisa.
norepo="$work/norepo"
mkdir -p "$norepo"
got=$(hook_text 0 s8 "$fixtures/transcript-array.jsonl" "$norepo")
expected='*Claude Code*
• *evento:* `Stop`
• *sesión:* `s8`
• *agente:* `notify-agente-array`'
if [ "$got" = "$expected" ]; then ok "fuera de git: sin rama ni tarea"; else ko "fuera de git" "got: $got"; fi

# 9. Transcript ilegible o con líneas rotas: no falla y cae al fallback.
printf 'no es json\n{"type":"user","message":{"content":"notify: tras-basura"}}\n' >"$work/roto.jsonl"
mkdir -p "$work/dir.jsonl"
for nojq in 0 1; do
  r=$(hook_text $nojq s9 "$work/roto.jsonl")
  d=$(hook_text $nojq s9 "$work/dir.jsonl"; echo "rc=$?")
  if [ "$(agent_line "$r")" = '• *agente:* `notify-tras-basura`' ] &&
    printf '%s\n' "$d" | grep -qxF '• *agente:* `desconocido`' && printf '%s' "$d" | grep -q 'rc=0'; then
    ok "líneas rotas se saltean; transcript que no es archivo → desconocido (NOTIFY_NO_JQ=$nojq)"
  else
    ko "transcript roto (NOTIFY_NO_JQ=$nojq)" "r=[$r] d=[$d]"
  fi
done

# 10. jq y sin jq dan el mismo payload para cada fixture.
same=1
for fx in "$fixtures"/*.jsonl; do
  [ "$(hook_text 0 s10 "$fx")" = "$(hook_text 1 s10 "$fx")" ] || { same=0; ko "jq ≠ sin jq: $(basename "$fx")"; }
done
[ "$same" = 1 ] && ok "jq = sin jq en todas las fixtures"

# 11. Las fixtures solo tienen ids placeholder (ceros).
bad=$(grep -hoE '"(sessionId|uuid|leafUuid)":"[^"]*"' "$fixtures"/*.jsonl | grep -vE ':"0{8}-0{4}-0{4}-0{4}-0{9}[0-9]{3}"$')
if [ -z "$bad" ]; then ok "fixtures con ids placeholder"; else ko "fixtures con ids no placeholder" "$bad"; fi

echo
echo "pasaron: $pass  fallaron: $fail"
[ "$fail" = 0 ]
