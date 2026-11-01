#!/usr/bin/env bash
# run_llama_test.sh <llama-completion> <model.gguf> - llama.cpp целиком с f2qdsp (mock-сборка, DSP в процессе):
#  * при F2QDSP=1 веса Q4_0/Q8_0 должны лечь в буфер F2QDSP и DSP должен реально вызываться;
#  * текст (greedy) при F2QDSP=1, F2QDSP=1 F2QDSP_SPLIT=1 и F2QDSP=cpu должен совпасть бит в бит
#    (DSP и CPU считают формат f2q одинаково); с обычным CPU (F2QDSP=0) - только для сведения.
#  -lv 4: без него llama.cpp (v0.8.0) скрывает INFO-строки библиотеки (load_tensors, f2qdsp-лог вызовов).
set -uo pipefail
BIN=${1:?llama-completion}
M=${2:?model.gguf}
W=${WORK:-llama_test}
mkdir -p "$W"
FAIL=0
run() { # run <имя> <переменные...>
  N=$1; shift
  if ! env -u F2QDSP -u F2QDSP_SPLIT "$@" "$BIN" -m "$M" -p "Once upon a time" -n 64 --temp 0 -s 1 -t 4 -c 256 \
       -no-cnv --no-display-prompt --no-warmup -lv 4 >"$W/$N.txt" 2>"$W/$N.log" </dev/null; then
    tail -n 30 "$W/$N.log"; echo "ERROR: llama-completion упал ($N)"; FAIL=1
  fi
  echo "== $N: $(grep -E 'model buffer size = +[0-9]*[1-9]' "$W/$N.log" | sed 's/.*load_tensors: *//' | tr -s ' ' | paste -sd ';' -)"
  echo "   текст: $(tr '\n' ' ' <"$W/$N.txt" | cut -c1-160)"
}
run cpu0 F2QDSP=0
run f2q_cpu F2QDSP=cpu
run dsp F2QDSP=1 F2QDSP_DEBUG=1
run dsp_all F2QDSP=1 F2QDSP_SPLIT=1
grep -h "f2qdsp:" "$W/dsp.log" | head -n 3
for N in f2q_cpu dsp dsp_all; do
  grep -q "F2QDSP model buffer size" "$W/$N.log" || { echo "ERROR: $N: веса не попали в буфер F2QDSP"; FAIL=1; }
done
grep -q "F2QDSP model buffer size" "$W/cpu0.log" && { echo "ERROR: без F2QDSP буфер F2QDSP появился"; FAIL=1; }
grep -q "selftest q4: OK" "$W/dsp.log" || { echo "ERROR: DSP (mock) не прошёл самопроверку"; FAIL=1; }
grep -q "плиток за" "$W/dsp.log" || { echo "ERROR: нет вызовов DSP в логе (F2QDSP_DEBUG)"; FAIL=1; }
[ -s "$W/f2q_cpu.txt" ] || { echo "ERROR: пустой вывод"; FAIL=1; }
for N in dsp dsp_all; do
  cmp -s "$W/f2q_cpu.txt" "$W/$N.txt" || { echo "ERROR: текст $N отличается от F2QDSP=cpu"; diff "$W/f2q_cpu.txt" "$W/$N.txt" | head; FAIL=1; }
done
if cmp -s "$W/cpu0.txt" "$W/f2q_cpu.txt"; then echo "текст совпал и с обычным CPU (F2QDSP=0)"
else echo "для сведения: текст отличается от обычного CPU (F2QDSP=0) - другая (fixed-point) арифметика масштабов"; fi
[ "$FAIL" = 0 ] && echo "llama test: OK" || echo "llama test: ЕСТЬ ОШИБКИ"
exit "$FAIL"
