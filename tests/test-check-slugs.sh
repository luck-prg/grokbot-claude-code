#!/usr/bin/env bash
# Casos de local/check-slugs.
# Uso: bash tests/test-check-slugs.sh   — sale ≠0 si falla algún caso.

set -u

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cs="$repo_dir/local/check-slugs"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# expect <nombre> <código esperado> <patrón esperado en la salida o ""> -- <args...>
# La entrada estándar se hereda del llamador.
expect() {
  local name="$1" want="$2" pattern="$3" out rc
  shift 4
  out=$(bash "$cs" "$@" 2>&1)
  rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$pattern" ] || printf '%s' "$out" | grep -q -- "$pattern"; }; then
    ok "$name"
  else
    ko "$name" "rc=$rc (esperado $want) out=[$out]"
  fi
}

expect "set válido → 0" 0 "ok: 2" -- luciano-dev maria-ops </dev/null
expect "notify-dev vs notify-dev-ml → 1" 1 "colisión por substring: notify-dev-ml contiene a notify-dev" -- dev dev-ml </dev/null
expect "colisión en cualquier orden → 1" 1 "colisión por substring" -- dev-ml otro dev </dev/null
expect "duplicados → 1" 1 "duplicado 'ana'" -- ana ana </dev/null
expect "duplicado con y sin prefijo → 1" 1 "duplicado 'ana'" -- ana notify-ana </dev/null
expect "mayúsculas → 1" 1 "inválido 'Luciano'" -- Luciano maria </dev/null
expect "espacio → 1" 1 "inválido 'mi bot'" -- 'mi bot' maria </dev/null
expect "guion inicial → 1" 1 "inválido '-dev'" -- -dev maria </dev/null
expect "prefijo notify- aceptado → 0" 0 "ok: 2" -- notify-luciano-dev notify-maria-ops </dev/null
expect "prefijo notify- también detecta colisión → 1" 1 "colisión por substring" -- notify-dev notify-dev-ml </dev/null
expect "stdin, uno por línea → 0" 0 "ok: 3" -- < <(printf 'luciano-dev\n\nmaria-ops\n  notify-juan  \n')
expect "stdin con colisión → 1" 1 "colisión por substring" -- < <(printf 'dev\ndev-ml\n')
expect "sin input → 2" 2 "uso:" -- </dev/null

echo
echo "pasaron: $pass  fallaron: $fail"
[ "$fail" = 0 ]
