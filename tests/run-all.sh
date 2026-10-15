#!/usr/bin/env bash
# Corre todos los tests (tests/*.sh salvo este) y resume. Sale ≠0 si alguno falla.
# Uso: bash tests/run-all.sh

set -u

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
self=$(basename "${BASH_SOURCE[0]}")

passed=()
failed=()
for t in "$tests_dir"/*.sh; do
  name=$(basename "$t")
  [ "$name" = "$self" ] && continue
  echo "=== $name"
  if bash "$t"; then
    passed+=("$name")
  else
    failed+=("$name")
  fi
  echo
done

echo "=== resumen"
for n in "${passed[@]}"; do printf 'ok   %s\n' "$n"; done
for n in "${failed[@]}"; do printf 'FAIL %s\n' "$n"; done
echo
echo "pasaron: ${#passed[@]}  fallaron: ${#failed[@]}"
[ "${#failed[@]}" = 0 ]
