#!/usr/bin/env bash
# run_llama_test.sh <llama-completion> <model.gguf> [llama-perplexity] - llama.cpp целиком с f2qdsp (mock-сборка, DSP в процессе):
#  * при F2QDSP=1 веса Q4_0/Q8_0 должны лечь в буфер F2QDSP и DSP должен реально вызываться;
#  * текст (greedy) при F2QDSP=1, F2QDSP=1 F2QDSP_SPLIT=1 и F2QDSP=cpu должен совпасть бит в бит
#    (DSP и CPU считают формат f2q одинаково); с обычным CPU (F2QDSP=0) - только для сведения;
#  * с llama-perplexity: perplexity на тексте модели при F2QDSP=cpu и F2QDSP=1 отличается от обычного CPU меньше
#    чем на 0.5% (точность масштабов f2q на настоящей модели, а не только на случайных матрицах).
#  -lv 4: без него llama.cpp (v0.8.0) скрывает INFO-строки библиотеки (load_tensors, f2qdsp-лог вызовов).
set -uo pipefail
BIN=${1:?llama-completion}
M=${2:?model.gguf}
PPL=${3:-}
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
if [ -n "$PPL" ]; then
  # текст - сама модель с температурой (свой для любой модели; F2QDSP=0 - обычный CPU)
  env -u F2QDSP -u F2QDSP_SPLIT F2QDSP=0 "$BIN" -m "$M" -p "Once upon a time" -n 480 --ignore-eos --temp 0.8 -s 7 -t 4 -c 512 \
    -no-cnv --no-warmup >"$W/ppl_text.txt" 2>"$W/ppl_text.log" </dev/null || { tail -n 20 "$W/ppl_text.log"; FAIL=1; }
  ppl() { # ppl <имя> <переменные...> -> число PPL
    N=$1; shift
    env -u F2QDSP -u F2QDSP_SPLIT "$@" "$PPL" -m "$M" -f "$W/ppl_text.txt" -c 128 -b 128 -t 4 >"$W/ppl_$N.log" 2>&1 </dev/null
    sed -n 's/.*Final estimate: PPL = \([0-9.]*\).*/\1/p' "$W/ppl_$N.log" | tail -n 1
  }
  P0=$(ppl cpu0 F2QDSP=0); P1=$(ppl f2q_cpu F2QDSP=cpu); P2=$(ppl dsp F2QDSP=1)
  echo "perplexity: F2QDSP=0 $P0, F2QDSP=cpu $P1, F2QDSP=1 $P2"
  for V in "cpu:$P1" "1:$P2"; do
    if [ -z "$P0" ] || [ -z "${V#*:}" ]; then echo "ERROR: llama-perplexity не дал PPL"; tail -n 20 "$W/ppl_cpu0.log"; FAIL=1
    elif awk -v a="${V#*:}" -v b="$P0" 'BEGIN { d = a / b - 1; exit !(d < 0.005 && d > -0.005) }'; then
      echo "perplexity F2QDSP=${V%%:*}: отличие от обычного CPU $(awk -v a="${V#*:}" -v b="$P0" 'BEGIN { printf "%.4f%%", (a / b - 1) * 100 }')"
    else echo "ERROR: perplexity F2QDSP=${V%%:*} (${V#*:}) отличается от обычного CPU ($P0) больше чем на 0.5%"; FAIL=1; fi
  done
fi
[ "$FAIL" = 0 ] && echo "llama test: OK" || echo "llama test: ЕСТЬ ОШИБКИ"
exit "$FAIL"
