#!/usr/bin/env bash
# run_ggml_test.sh <ggml_test> - прогон ggml_test во всех режимах f2qdsp (нужна mock-сборка ggml: DSP в процессе).
set -uo pipefail
T=${1:?ggml_test}
FAIL=0
run() { # run <описание> <переменные...>
  echo "===== $1"; shift
  if env -u F2QDSP -u F2QDSP_SPLIT "$@" "$T"; then echo "----- OK"; else echo "ERROR: ggml_test ($*)"; FAIL=1; fi
}
run "без F2QDSP (буфер не должен регистрироваться)"
run "F2QDSP=1 (DSP-эмуляция + CPU, доля подбирается)" F2QDSP=1
run "F2QDSP=cpu (формат f2q, только CPU)" F2QDSP=cpu
run "F2QDSP_SPLIT=0 (всё на CPU)" F2QDSP=1 F2QDSP_SPLIT=0
run "F2QDSP_SPLIT=1 (всё на DSP)" F2QDSP=1 F2QDSP_SPLIT=1
run "F2QDSP_SPLIT=0.5, 2 потока" F2QDSP=1 F2QDSP_SPLIT=0.5 THREADS=2
[ "$FAIL" = 0 ] && echo "ggml_test: все режимы OK" || echo "ggml_test: ЕСТЬ ОШИБКИ"
exit "$FAIL"
