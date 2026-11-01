# shellcheck shell=bash
# общие проверки для тестов linux/test (подключается через source)
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { # bad <описание> [файл с выводом]
  FAIL=$((FAIL + 1)); echo "  FAIL: $1"
  if [ -n "${2:-}" ] && [ -f "$2" ]; then tail -n 40 "$2" | sed 's/^/    | /'; fi
}
has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (нет строки: $2)" "$1"; fi; }   # has <файл> <строка> <что>
hasnt() { if grep -qF -- "$2" "$1"; then bad "$3 (лишняя строка: $2)" "$1"; else ok "$3"; fi; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (ожидалось '$2', получено '$1')" "${4:-}"; fi; } # eq <есть> <надо> <что> [файл]
finish() { # finish <название>: итог; TEST_SUMMARY=<файл> - дописать итог и туда (CI кладёт его в описание релиза)
  echo "== $1: $PASS ok, $FAIL FAIL"
  if [ -n "${TEST_SUMMARY:-}" ]; then echo "== $1: $PASS ok, $FAIL FAIL" >>"$TEST_SUMMARY"; fi
  [ "$FAIL" = 0 ]
}
