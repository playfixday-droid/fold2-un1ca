# npu/ — f2qdsp: llama.cpp на cDSP (Hexagon 698) Snapdragon 865

Свой драйвер, потому что `ggml-hexagon` из llama.cpp поддерживает только Hexagon v73+, а у Fold2 (SM8250) cDSP **v66**
(HVX 128 байт, без HVX float). f2qdsp считает на DSP только `MUL_MAT` с весами **Q4_0 / Q8_0**, всё остальное — на CPU.

> **На телефоне не запускалось.** Проверено только в CI и эмуляторах (см. «Что проверено»). Работает ли DSP на
> серийном Fold2 — станет ясно после `npu.sh test`.

## Как пользоваться (телефон с root)
Ставит всё `linux/pc_install_debian.sh` с ПК (раздел NPU). Вручную:
```bash
# архив f2qdsp-android-arm64.tar.xz из Releases -> tools-<N>
adb push f2qdsp-android-arm64.tar.xz /data/local/tmp/
adb shell su -c "'mkdir -p /data/local/tmp/fold2-npu && /data/adb/magisk/busybox tar -xJf /data/local/tmp/f2qdsp-android-arm64.tar.xz -C /data/local/tmp/fold2-npu'"
adb push Qwen3-1.7B-Q4_0.gguf /sdcard/models/
adb shell su -c "'sh /data/local/tmp/fold2-npu/npu.sh test'"     # работает ли DSP
adb shell su -c "'sh /data/local/tmp/fold2-npu/npu.sh server'"   # http://<IP телефона>:8081
```
Команды `npu.sh`:

| Команда | Что делает |
|---|---|
| `test [M K]` | `f2q-bench`: открылся ли DSP, совпадает ли результат с CPU (бит в бит), скорость DSP и CPU. Код 0 — DSP работает, 3 — DSP не открылся (CPU в порядке), 1 — ошибка. Если DSP не открылся с основным кодом DSP, сам пробует запасной (`dsp/eld/`) и запоминает сработавший в `dsp.variant` |
| `server [модель]` | `llama-server` на `0.0.0.0:8081` в фоне. Модель — путь или имя `.gguf`; ищется в `/sdcard/models`, затем в кэше llama.cpp Debian (`/data/local/fold2/debian/var/lib/llama`). По умолчанию `Qwen3-1.7B-Q4_0.gguf` |
| `bench [модель]` | `llama-bench` три раза: `F2QDSP=0` (обычный CPU), `cpu` (формат f2q на CPU), `1` (DSP + CPU) |
| `stop` | остановить `llama-server` |
| `log [dsp]` | конец лога сервера; `log dsp` — сообщения FastRPC/DSP из logcat |

Настройки — `/data/local/tmp/fold2-npu/npu.conf` (необязательно): `NPU_MODEL`, `NPU_PORT`, `NPU_THREADS` (4),
`NPU_CPUMASK` (`f0` = ядра 4–7), `NPU_CTX` (4096), `NPU_API_KEY`, `NPU_ARGS`, `NPU_LOG_LEVEL` (4),
`NPU_SKEL` (`auto` — что сработало в `test`, иначе `lld`; `lld` или `eld` — принудительно), а также
`export F2QDSP_...` из таблицы ниже. Модели можно искать и в других папках: `NPU_MODEL_DIRS="/sdcard/models /sdcard/Download"`.

После старта `npu.sh server` пишет, сколько весов легло на DSP (`на DSP: веса … MiB`) или что DSP не задействован.
Для этого сервер запускается с `-lv 4`: llama.cpp v0.8.0 на уровне 3 прячет INFO-строки библиотеки
(`F2QDSP model buffer size`, лог `F2QDSP_DEBUG`). Строка состояния DSP (версия, самопроверка, задержка вызова) видна в
`npu.sh test`; в логе сервера — только с `NPU_LOG_LEVEL=5`.

Папка: `bin/` (llama-server, llama-cli, llama-bench, f2q-bench), `dsp/libf2qdsp_skel.so` (код для DSP, линкер `ld.lld`),
`dsp/eld/libf2qdsp_skel.so` (те же объектные файлы, линкер ELD из Hexagon SDK — его вывод устроен как у стоковых
библиотек: `DT_SYMBOLIC`, `DT_HEXAGON_VER`, без `PT_PHDR`), `lib/`, `npu.sh`.
Окружение задаёт `npu.sh`: `LD_LIBRARY_PATH=$D/lib:/vendor/lib64`,
`ADSP_LIBRARY_PATH="$D/dsp;/vendor/dsp/cdsp;/vendor/dsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp"` (с `eld` —
`$D/dsp/eld;…`), такая же
`DSP_LIBRARY_PATH` (если она задана, `libcdsprpc` Fold2 смотрит только её) и `F2QDSP=1`.

## Переменные окружения

| Переменная | Что делает |
|---|---|
| `F2QDSP=1` | включает DSP (без неё буфер F2QDSP не регистрируется и llama.cpp работает как обычно) |
| `F2QDSP=cpu` | формат f2q, но считается только на CPU (NEON) |
| `F2QDSP_SPLIT=0..1` | фиксированная доля плиток на DSP (иначе подбирается сама, отдельно для n ≤ 4 и n > 4) |
| `F2QDSP_MAX_MB` | лимит весов на DSP, по умолчанию 1024 (остальные веса — обычный CPU) |
| `F2QDSP_THREADS` | потоков на DSP, по умолчанию 4 |
| `F2QDSP_SAFE=1` | не менять атрибуты регистрации общей памяти (`KEEP_MAP`, `FORCE_NOFLUSH`). Если самопроверка с ними не проходит, это включается само |
| `F2QDSP_SIGNED=1` | не включать unsigned PD |
| `F2QDSP_DEBUG=1` | лог подстройки доли DSP (каждый 50-й вызов: матрица, плиток на DSP, время); в llama.cpp виден с `-lv 4` |

## Как устроено
- `idl/f2qdsp.idl` — интерфейс FastRPC (`info`, `power`, `mm`); `qaic` из Hexagon SDK делает из него
  `f2qdsp.h`, `f2qdsp_stub.c`, `f2qdsp_skel.c`. В IDL только ASCII — с UTF-8 qaic падает.
- `common/f2q_format.h` — формат: плитки по 32 строки весов, масштабы в fixed point, поэтому DSP, NEON и
  скалярный эталон дают **одинаковый результат бит в бит**. `common/f2q_pack.c` — перепаковка блоков ggml
  Q4_0/Q8_0, квантование активаций как q8_0 в ggml.
- `dsp/f2q_kernel.c` — ядро HVX (`vrmpy`) и скалярный эталон; `dsp/f2qdsp_imp.c` — DSP-часть: голос HAP_power
  (TURBO), до 4 потоков QuRT, без HVX — эталон. `dsp/fix_gotplt.py` — правка `.got.plt` после `ld.lld` (см. выше),
  `dsp/fastrpc_shell_unsigned_3.syms` — что экспортирует оболочка cDSP Fold2.
- `ap/f2q_cpu.c` — то же на NEON dotprod; `ap/f2q_dev.c` — связь с DSP: `libcdsprpc.so` через `dlopen`,
  unsigned PD, веса в rpcmem (heap 25, размеры кратны 4 КБ), самопроверка DSP против эталона при старте (веса
  регистрируются так же, как настоящие; не прошла с атрибутами — повтор без них); после 8 ошибок DSP отключается.
- `ggml/ggml-f2qdsp.cpp` — дополнительный тип буфера CPU-бэкенда `F2QDSP` (как repack/AMX): забирает `MUL_MAT`
  с 2D-весами Q4_0/Q8_0, первые плитки считает DSP (один вызов из потока 0), остальные — потоки CPU.
- `patch_llama.py` — подключает всё это к llama.cpp **v0.8.0** (повторный запуск безопасен).
- `phone/npu.sh` — запуск на телефоне. `test/` — тесты (ниже).

## Что проверено (CI: `.github/workflows/tools.yml`, задачи «NPU f2qdsp» и «ggml test arm64 + llama mock»)
- ядро HVX в `qemu-hexagon` (v66, HVX 128) = скалярный эталон бит в бит, NMSE против ggml ~1e-9 (`test/kernel_test.c`);
- NEON dotprod на arm64 = эталон бит в бит (тот же тест с `-DF2Q_TEST_CPU`);
- `libf2qdsp_skel.so` собирается под v66: `e_flags 0x66`, 2 сегмента LOAD по 4 КБ (как у стоковых skel), внешние
  символы — `HAP_power_set`, `__wrap_malloc`, `__wrap_free`, `memset`, `qurt_*`. CI сверяет их со списком экспортов
  стоковой оболочки `fastrpc_shell_unsigned_3` Fold2 (`dsp/fastrpc_shell_unsigned_3.syms`) и падает, если чего-то нет;
  слоты `.got.plt` указывают на PLT0, как у стоковых библиотек (`dsp/fix_gotplt.py --check`); те же проверки
  проходит запасной вариант `dsp/eld/` (ELD 21 из SDK 6.7.0.0 не знает v66 и пишет `e_flags 0x68` —
  `fix_gotplt.py --eflags=0x66` ставит 0x66, код в объектниках собран под v66);
- FastRPC-маршалинг: настоящие stub/skel от qaic с DSP-частью в том же процессе (`test/mock/`), `f2q-bench` → `ИТОГ: OK`;
  регистрация буферов в mock повторяет `libcdsprpc` из `quic/fastrpc` (счётчик ссылок, `abort()` при снятии регистрации
  с другим размером): старая версия `f2q_dev.c` на этом падала, текущая — нет (и в `f2q-bench`, и в llama.cpp целиком);
- интеграция в ggml (`test/ggml_test.cpp`): MUL_MAT в буфере F2QDSP против обычного CPU — Q4_0/Q8_0,
  200×512, 96×4096, 1000×2048, 33×32, n = 1/3/7/64, по 12 прогонов, NMSE < 1e-6 и одинаковый результат всех прогонов;
  режимы `F2QDSP=1`, `cpu`, `F2QDSP_SPLIT=0`, `1` (на x86 и на arm64);
- llama.cpp целиком с моделью (stories15M Q4_0, эмуляция DSP): веса ложатся в буфер F2QDSP (12.8 MiB), DSP
  вызывается, текст (greedy) при `F2QDSP=1`, `F2QDSP=1 F2QDSP_SPLIT=1` и `F2QDSP=cpu` одинаковый
  (`test/run_llama_test.sh`); с обычным CPU (`F2QDSP=0`) текст расходится через пару десятков токенов — другая (fixed-point)
  арифметика масштабов, это ожидаемо;
- `npu.sh` под `busybox ash` (как `sh` на телефоне, но без toybox): `test` (коды 0/1/2), `server` (поиск модели,
  pid самого llama-server, ответ на `/v1/chat/completions`), повторный `server`, `log`, `stop` (процесс действительно
  завершается), `bench` (F2QDSP=0/cpu/1 доходят до llama-bench, `taskset` получает маску); `shellcheck -s sh` чистый.
  На x86 цифры скорости в mock-режиме ничего не значат (f2q на x86 — скалярный код);
- сборка под Android (NDK, android-30): `llama-server`, `llama-cli`, `llama-bench`, `f2q-bench` — AArch64, зависят
  только от `libc`/`libm`/`libdl`, внутри есть f2qdsp (`libcdsprpc.so` через `dlopen`, URI `…&_dom=cdsp`) и
  веб-интерфейс llama-server; архив распаковывается `busybox tar` из Magisk;
- toolchain: clang/lld 22.1.8 из `qualcomm/toolchain_for_hexagon` (релиз v22.1.8, sha256 сверяется в CI);
  `clang-18`/`lld-18` из Ubuntu 24.04 тоже собирают skel (e_flags 0x66, без лишних внешних символов).

## Проверено по стоковой прошивке Fold2 (SM-F916B, F916BXXS7KXH1; файлы прошивки, не телефон)
- в `/vendor/dsp/cdsp` (образ `dspso.bin` из BL) есть `fastrpc_shell_unsigned_3` и `fastrpc_shell_3`;
- прошивка cDSP (`NON-HLOS.bin`, `CDSP.HT.2.3-00595-SM8250-3`) содержит код unsigned PD («Creating unsigned process»,
  `/statichashes/fastrpc_shell_unsigned_3`, «QDI_OPEN UNSIGNED PD»);
- `/vendor/lib64/libcdsprpc.so` (vendor Android 11) умеет `remote_session_control` и `set_unsigned_pd_attribute`,
  ищет файлы по `DSP_LIBRARY_PATH` (приоритет) или `ADSP_LIBRARY_PATH`, по умолчанию
  `;/vendor/lib/rfsa/adsp;/vendor/lib/rfsa/dsp;/vendor/dsp`;
- `ueventd`: `/dev/adsprpc-smd` — `0664 system`, `/dev/ion` — `0664` (root их открывает);
- **найден и исправлен баг**: до tools-8 `libf2qdsp_skel.so` импортировал `free`, а оболочки cDSP Fold2 экспортируют только
  `__wrap_free` (стоковые skel тоже используют `__wrap_*`) — DSP отказался бы загружать библиотеку. Теперь skel линкуется
  как в Hexagon SDK (`-Bsymbolic`, `--wrap=malloc/calloc/free/realloc/memalign`).
- **ещё одно отличие от стока, исправлено**: у всех 17 Hexagon-библиотек стока в `/vendor/lib/rfsa/adsp` (и у skel в
  `/vendor/dsp/cdsp`) слоты `.got.plt` содержат адрес PLT0 — по нему загрузчик cDSP (rtld из NetBSD) делает ленивое
  связывание. `ld.lld` оставляет там нули: если загрузчик свяжет символы лениво, первый же вызов `memset`/`HAP_power_set`
  ушёл бы на начало файла. С tools-12 `dsp/fix_gotplt.py` после линковки записывает туда адрес PLT0 (код PLT у lld и у
  стоковых skel одинаковый, проверено дизассемблером). Скорее всего skel грузится с `RTLD_NOW` (так в `mod_table.c` из
  `quic/fastrpc`), и тогда это было не критично, но теперь файл устроен как стоковый в обоих случаях.
- остальные отличия `ld.lld` от стока (`DT_FLAGS` вместо `DT_SYMBOLIC`, нет `DT_HEXAGON_VER`, есть `PT_PHDR`) загрузчик,
  судя по его сообщениям об ошибках (проверяет только `DT_RELENT`/`DT_RELAENT`/`DT_PLTREL`/`DT_SYMENT`, магию, класс,
  тип ELF, заголовки программы), не проверяет. На всякий случай с tools-12 есть вариант `dsp/eld/` без этих отличий,
  и `npu.sh test` пробует его сам.

## Что НЕ проверено и честные ограничения
- **Ничего не запускалось на телефоне.** Ни открытие сессии с cDSP, ни скорость.
- **Unsigned PD.** Поддержка в прошивке есть (см. выше), но пустит ли её Samsung на практике (политика/SELinux),
  видно только на телефоне. Если нет — сессия не откроется,
  `npu.sh test` покажет `DSP недоступен`, а llama.cpp сам уйдёт на CPU. Testsig на серийном аппарате не сработает.
- **Генерация (n = 1) вряд ли станет быстрее.** Один вызов FastRPC стоит ~0.2–0.5 мс; выигрыш возможен на обработке
  промпта (n > 4). Доля DSP подбирается сама и может уйти почти в ноль, если DSP проигрывает.
- **Адресное пространство DSP 32-битное** — только небольшие модели (1–2B), лимит `F2QDSP_MAX_MB`.
- Только веса Q4_0/Q8_0 (2D). Модели Q4_K_M и т.п. работают целиком на CPU.
- **CPU-часть f2q может быть медленнее обычного llama.cpp.** Плитки, которые не взял DSP, считаются NEON-кодом
  формата f2q, а не оптимизированными (repack) ядрами ggml. Итог покажет `npu.sh bench`: если `F2QDSP=1` не быстрее
  `F2QDSP=0` — пользуйся обычным llama.cpp (Debian, `debian.sh llama`).
- `toybox taskset` на телефоне не проверен (в CI — busybox и подмена `taskset`).
- Держи всё в `/data/local/tmp/…`: по правилам линкера Android (linkerconfig, секция `unrestricted`) бинарник оттуда
  может загрузить `/vendor/lib64/libcdsprpc.so`. Из других мест `/data` нужен `LD_LIBRARY_PATH` с `/vendor/lib64`
  (`npu.sh` его задаёт).
- Для сведения: в ядре f2q-3 FastRPC (`CONFIG_MSM_ADSPRPC`), загрузчик cDSP и ION включены (проверено по `ikconfig`).
  Что нашлось в интернете: unsigned PD на cDSP у Samsung работает как минимум на Galaxy S25 Ultra (SM8750, проект
  nntrainer); про SM8250 разработчик MACE (Xiaomi) писал, что unsigned PD там «works just fine». Отчётов о запуске на
  Samsung с SM8250 не нашёл. Для unsigned PD нужен файл `fastrpc_shell_unsigned_3` (на Fold2 — `/vendor/dsp/cdsp`) —
  `npu.sh test` при неудаче показывает, есть ли он.

## Сборка вручную
Всё, что делает CI, — в `.github/workflows/tools.yml` (задача `npu`): Hexagon SDK 6.7.0.0 (заголовки, qaic, QuRT),
clang/lld 22.1.8 для Hexagon (qualcomm/toolchain_for_hexagon), NDK. Кратко:
```bash
Q=<Hexagon SDK>; $Q/ipc/fastrpc/qaic/bin/qaic -mdll -I $Q/incs -I $Q/incs/stddef npu/idl/f2qdsp.idl -o gen/
python3 npu/patch_llama.py <llama.cpp v0.8.0>
cmake -S llama.cpp -B build -DGGML_CPU_F2QDSP=ON -DGGML_CPU_F2QDSP_SRC=$PWD/npu -DGGML_CPU_F2QDSP_GEN=$PWD/gen \
      -DGGML_CPU_F2QDSP_SDK=$Q [-DGGML_CPU_F2QDSP_MOCK=ON]   # MOCK - DSP в процессе, для тестов на ПК
```
Skel для DSP: `clang --target=hexagon-unknown-elf -mv66 -mhvx -mhvx-length=128b -G0 -fPIC -O2 -ffp-contract=off` для
`dsp/f2qdsp_imp.c`, `dsp/f2q_kernel.c`, `gen/f2qdsp_skel.c`, затем `ld.lld` с флагами из шага «DSP skel (v66)» в
`tools.yml` и обязательно `python3 npu/dsp/fix_gotplt.py libf2qdsp_skel.so`. Вариант ELD: `ld.eld` из
`$Q/tools/HEXAGON_Tools/21.0.04/Tools/bin` с теми же `-shared -Bsymbolic --hash-style=sysv --wrap=…`, затем
`fix_gotplt.py --eflags=0x66`.
