# linux/ — Debian 13 (trixie) в chroot на Fold2: XFCE в DeX, Docker, Vulkan (Turnip), llama.cpp

Полноценный Debian 13 arm64 рядом с Android (chroot, без эмуляции): рабочий стол XFCE через Termux:X11 (окно
уводится на монитор в DeX), Docker, `ssh`, Vulkan на Adreno 650 через Turnip (Mesa, KGSL), llama.cpp на CPU или
Vulkan. NPU (cDSP) — отдельно, в Android: см. [`npu/README.md`](../npu/README.md).

> **На телефоне не запускалось.** Проверено только то, что перечислено в «Что проверено».

## Что нужно
- Прошивка `f2q-N` из Releases с root: AP уже содержит boot с **Magisk v31.1**. Приложение Magisk установщик ставит
  сам, если его нет (`Magisk-v<версия>.apk` той же версии, что в boot, из релиза `f2q-N`, sha256 из его `SHA256SUMS`;
  нет там — официальный релиз topjohnwu, sha256 из API GitHub; без проверенной суммы не ставит), и открывает его:
  на запрос root для **Shell** — «Разрешить», на «Требуется дополнительная настройка» — OK (телефон перезагрузится;
  без неё нет `/data/adb/magisk` — Magisk не запускает автозапуск Debian, `debian.sh` нечем распаковать rootfs).
  Скрипт ждёт до 15 минут. Нет `su` вообще (прошит `BOOT_noroot`) — скажет прошить AP из `f2q-N`.
  Вернуть boot без root — `BOOT_noroot_f2q.tar.md5` в Odin (слот AP).
- ПК с `curl`, USB-отладка, интернет на ПК и телефоне. `adb` ставить не обязательно: если его нет, установщик сам
  скачает официальные platform-tools Google в `linux/fold2-dl/platform-tools` (Linux, macOS, Windows); так же — если
  свой `adb` старше 1.0.39 (он не передаёт коды ошибок команд на телефоне). Если телефон
  не виден, скрипт подскажет причину: не разрешена отладка, нет прав USB (Linux, udev), нет драйвера Samsung (Windows),
  несколько устройств. Windows — через Git Bash (из Git for
  Windows): скрипты в репозитории всегда с переводами строк LF (`linux/.gitattributes`), а установщик ещё и сам убирает
  CR из скриптов перед отправкой на телефон. Подключено несколько устройств — `ANDROID_SERIAL=<серийник> bash ...`. ~8 ГБ свободного места на телефоне (Debian с XFCE/Docker ~4 ГБ, модели 1–2.5 ГБ).

## Проверка телефона после прошивки (root не нужен)
Сразу после первой загрузки прошивки, ещё до Magisk (и после каждого обновления):
```bash
bash linux/pc_check_phone.sh               # ИТОГ на экране, отчёт linux/fold2-check-<время>.txt
```
Без ПК-скрипта: `adb push linux/phone/check_phone.sh /data/local/tmp/ && adb shell sh /data/local/tmp/check_phone.sh`.
Ничего на телефоне не меняет. Проверяет: загрузку (модель, сборка, загрузчик, время работы), уровень отладки, root и
Magisk, SELinux, службы init, которые перезапускаются по кругу, модем и SIM (оператор, сеть, ошибки в логе radio),
Wi-Fi, Bluetooth, NFC, камеры, экран (размер, частота), датчики, батарею, cDSP (`/dev/adsprpc-smd`, подсистемы),
опции ядра для Docker (`/proc/config.gz`, тот же список, что `docker.config`; DEFEX/PROCA/FIVE), место на `/data`,
память, часы, интернет, падения приложений (crash, tombstones, ANR), отказы SELinux, модули Magisk, USB. С root —
подробнее (dmesg, `/proc/config.gz`). Итог — по пунктам: OK / ВНИМАНИЕ / НЕТ / ИНФО, ниже подробности. IMEI, серийные
номера, MAC, ICCID/IMSI, номера телефонов, почта заменяются на `***`, имя сети Wi-Fi не выводится — отчёт можно
присылать.

## Установка одной командой (с ПК)
```bash
bash linux/pc_install_debian.sh            # пользователь Debian по умолчанию fold2
bash linux/pc_install_debian.sh ivan       # свой пользователь
SKIP_NPU=1 bash linux/pc_install_debian.sh # без NPU;  SKIP_DEBIAN=1 - только NPU;  SKIP_MODEL=1 - без модели для NPU
RESTORE=~/fold2-backup/debian-<время>.tar.gz bash linux/pc_install_debian.sh  # Debian из копии (см. «Копия Debian»)
```
При первом `su` на внешнем экране появится запрос Magisk — разреши **Shell** (нет приложения Magisk или его
«дополнительной настройки» — скрипт сначала доводит root до конца, см. «Что нужно»). Скрипт сам, по порядку:
0. **копия EFS** (IMEI, ключи, калибровки радио; разделы только читаются) — на ПК в `~/fold2-backup/` (свою папку —
   `BACKUP_DIR=...`), sha256 сверяется, с телефона архив удаляется; если копия на ПК уже есть — пропускает.
   **Храни её и никому не отправляй.** Пропустить: `SKIP_BACKUP=1`;
1. **уровень отладки**: если не LOW (`0x4f4c`), спрашивает «Перезагрузить телефон и включить LOW?» (Enter — да;
   `reboot debug0x4f4c`, данные не трогает), ждёт именно новой загрузки (другой `boot_id`: пока телефон выключается,
   старая загрузка ещё отвечает) и проверяет уровень. Если остался MID/HIGH — проверку NPU
   пропускает (сбой DSP при таком уровне повесил бы телефон в Upload mode). Если телефон заблокирован — ждёт разблокировки;
2. берёт свежий rootfs Debian trixie arm64 с images.linuxcontainers.org и сверяет SHA256;
3. из последнего релиза `tools-N` этого репозитория (с наибольшим N: API GitHub отдаёт релизы по имени, `tools-9`
   раньше `tools-21`) качает `turnip-kgsl-debian13-arm64.tar.xz` и
   `llama-debian-arm64.tar.xz` (если их нет — `setup_in_chroot.sh` скачает сам или соберёт llama.cpp на телефоне);
4. ставит Termux:X11 (nightly `termux-x11-universal-debug.apk`);
5. на телефоне: `debian.sh install` (распаковка + `setup_in_chroot.sh`: XFCE, Firefox, Docker, Vulkan, сборочные
   пакеты, пользователь с `sudo` без пароля) — 10–30 минут, лог `/data/local/fold2/install.log`;
   затем `debian.sh ssh`, `debian.sh autostart on` и предел заряда 80 % (`BATT_LIMIT=80` в `debian.conf`; не ставить —
   `BATT_LIMIT= bash linux/pc_install_debian.sh`, свой — `BATT_LIMIT=90 …`);
6. NPU: `f2qdsp-android-arm64.tar.xz` → `/data/local/tmp/fold2-npu` (запущенный `npu.sh server` перед этим
   останавливается), модель `Qwen3-1.7B-Q4_0.gguf` → `/sdcard/models` (если там уже такая же — не копирует),
   `npu.sh test` (другая модель: `NPU_MODEL_URL=...`; папка загрузок: `WORK=...`). Итог проверки — в последних строках
   вывода и в отчёте: «DSP работает», «DSP не открылся, llama.cpp считает на CPU», «НЕ пройдена» или «телефон
   ПЕРЕЗАГРУЗИЛСЯ во время проверки» (сбой DSP или ядра: скрипт ждёт загрузки до 5 минут и всё равно пишет отчёт);
   и **рабочий стол**: `AUTO_X11=1` в `debian.conf` (XFCE поднимается при каждой загрузке; не надо —
   `AUTO_X11=0 bash linux/pc_install_debian.sh`; уже заданный в `debian.conf` без явного `AUTO_X11=` не меняется),
   кнопка в Magisk и сразу `debian.sh x11` — после установки рабочий стол уже открыт в Termux:X11 (см. «Телефон как компьютер»);
7. **проверка телефона** `phone/check_phone.sh` (как `pc_check_phone.sh`, см. ниже): пункты «НЕТ» и «ВНИМАНИЕ»
   выводит на экран, весь вывод — в отчёт. Пропустить: `SKIP_CHECK=1`;
8. пишет **отчёт** `linux/fold2-report-<время>.txt`: итог установщика (релиз `tools-N`, копия EFS, уровень отладки,
   Debian, предел заряда, NPU, итог проверки NPU, итог проверки телефона),
   версии прошивки, SELinux, версия Magisk, место на `/data`, память, `debian.sh status`, причины прошлых
   перезагрузок (`debian.sh bootlog ls`), вывод `npu.sh test`. IMEI и серийного номера в нём нет (`/proc/cmdline` целиком
   не берётся — там серийный номер) — его можно присылать.

Повторный запуск безопасен: скачанное берётся из `linux/fold2-dl/` (файлы из `tools-N` и rootfs сверяются с `SHA256SUMS`
их релиза; устаревший или битый файл качается заново). Если Debian уже стоит, скрипт его не переустанавливает, а
обновляет `debian.sh`, `setup_in_chroot.sh` и автозапуск, а удалённый Termux:X11 ставит снова (переставить Debian начисто:
`debian.sh remove yes`, затем снова `pc_install_debian.sh`). Если установка Debian оборвалась (пропала сеть, отключили
кабель) — скрипт всё равно ставит NPU и пишет отчёт (в нём конец `install.log`) и выходит с кодом 1; следующий запуск
**продолжает** установку: rootfs заново не качается и не распаковывается, снова идёт `setup_in_chroot.sh` (его можно
повторять). Законченная настройка отмечается файлом `/data/local/fold2/debian/etc/fold2-setup.done`. Если модель или
Termux:X11 не скачались — остальное доделывается, в выводе сказано, что повторить. Предел заряда, уже записанный в
`debian.conf` вручную, установщик не меняет. В Git Bash (Windows) пути телефона (`/data/...`, `/sdcard/...`)
не превращаются в пути Windows (`MSYS2_ARG_CONV_EXCL`).

## Телефон как компьютер
После `pc_install_debian.sh` рабочий стол XFCE уже запущен и поднимается сам при каждой загрузке (`AUTO_X11=1`):
1. Монитор по USB-C (кабель USB-C → HDMI/DP или хаб с зарядкой и USB) → включится DeX. Клавиатура и мышь — USB или
   Bluetooth. Без монитора — на экране телефона или с ПК: `scrcpy --new-display=1920x1080`.
2. Открой **Termux:X11** (в DeX — на мониторе) и разверни окно: там XFCE — Firefox, терминал, файлы (память телефона —
   `/sdcard`), `sudo apt install …` что угодно (например `libreoffice gimp vlc`), Docker. Язык — русский
   (английский: `debian.sh run sed -i s/^LANG=.*/LANG=en_US.UTF-8/ /etc/default/locale`, затем `x11 restart`). В настройках Termux:X11 включи перехват
   системных сочетаний (иначе Win/Alt+Tab забирает DeX).
3. Закрыл рабочий стол или он упал — **Magisk → Модули → «Fold2: Debian (компьютер)» → «Действие»** (без ПК и
   терминала): если XFCE работает — просто открывает Termux:X11, иначе поднимает Debian и XFCE; в конце — `status`
   (IP, ssh). Из терминала: `debian.sh x11` / `x11 restart` / `x11 stop`.
4. Доступ с ПК: `ssh -p 2222 fold2@<IP>` (пароль: `debian.sh run passwd fold2`), файлы — `scp`/`sftp`.

Пока рабочий стол запущен, SELinux в Permissive (`X11_SELINUX_PERMISSIVE=1`, требование Termux:X11 для chroot); с
`AUTO_X11=1` — с самой загрузки. Только по кнопке: `AUTO_X11=0` в `debian.conf`. XFCE постоянно занимает ~0,5 ГБ
памяти — на 12 ГБ Fold2 это немного. Звука из Debian пока нет (см. «Сервер 24/7» — PulseAudio через Termux).

## Копия Debian (перед перепрошивкой с очисткой данных)
```bash
bash linux/pc_backup_debian.sh            # -> ~/fold2-backup/debian-<время>.tar.gz и .sha256 (свою папку: BACKUP_DIR=...)
bash linux/pc_backup_debian.sh models     # вместе с моделями llama (/var/lib/llama)
bash linux/pc_backup_debian.sh restore ~/fold2-backup/debian-<время>.tar.gz   # вернуть
```
Копия идёт по USB сразу на ПК (`adb exec-out`, место на телефоне не нужно), там проверяется (`tar` читает её целиком,
Debian внутри) и получает `.sha256`. Работающий Debian на время копии останавливается — файлы не должны меняться на
ходу, а смонтированный внутрь `/sdcard` не должен попасть в копию (не размонтировался — отказ); потом снова
запускается то, что работало (`sshd`, `dockerd`, `llama-server`, рабочий стол). В копии весь Debian — домашние
каталоги, пакеты, настройки, пароли, ключи ssh — и `debian.conf`. **Не входят**: Docker (образы, контейнеры и тома —
`/var/lib/docker`; нужный том сохрани сам, например `docker run --rm -v том:/v -v /sdcard:/b debian tar czf /b/том.tgz -C /v .`),
кэш apt, `/tmp` и модели llama (скачаются заново; `models` — с ними). Владельцы (числами) и `setuid` сохраняются,
file capabilities (`setcap`) busybox tar не хранит — их список (`getcap -r /`) едет внутри копии и возвращается.
**В копии пароли и ключи — храни её у себя, никому не отправляй.**

`restore` — это `pc_install_debian.sh` с `RESTORE=<файл>`: на свежепрошитом телефоне он сам доведёт root (Magisk),
сделает копию EFS, если её ещё нет, поставит Termux:X11, вместо новой установки вернёт Debian из копии (сначала
сверит `.sha256` и прочитает копию; места на `/data` нужно на копию и распакованный Debian — проверяется заранее),
запустит `ssh`, автозапуск, рабочий стол, NPU — дальше как обычная установка. Поверх существующего Debian не кладёт
(убрать его: `debian.sh remove yes`). Распаковка идёт во временный каталог: оборвалась — Debian не появится наполовину.
`debian.conf` берётся из копии (прежний, если отличался, — `debian.conf.before-restore`). Без ПК, на самом телефоне:
`debian.sh backup <файл|-> [models]` и `debian.sh restore <файл|->`.

## Команды на телефоне
Всё от root, лучше через `su -mm` (глобальный mount namespace; скрипт и сам переходит в него через `nsenter`):
```bash
adb shell
su -mm -c "sh /data/local/fold2/debian.sh <команда>"
```

| Команда | Что делает |
|---|---|
| `install <rootfs.tar.xz> [пользователь]` | распаковать Debian в `/data/local/fold2/debian` и выполнить `setup_in_chroot.sh`; если прошлая установка оборвалась — продолжить её (`install - [пользователь]`, rootfs не нужен) |
| `start` / `stop` / `status` | смонтировать (`/proc`, `/sys`, `/dev`, `/dev/pts`, `/dev/shm`, `/run`, `/sdcard`, cgroup) / завершить процессы chroot (сначала корректно `dockerd`) и размонтировать / что запущено (и в каком cpuset), батарея, температура CPU/GPU/cDSP, IP |
| `shell [пользователь]` | войти (по умолчанию `DEB_USER`; `shell root` — root) |
| `run <команда…>` | выполнить команду в Debian от root, например `run passwd fold2`, `run apt install gimp` |
| `x11 [stop\|restart]` | рабочий стол XFCE в Termux:X11; в DeX окно Termux:X11 перетащи на монитор и разверни. Уже запущен — только открывает Termux:X11 (окна не теряются); `restart` — перезапустить, `stop` — остановить |
| `ssh` | `sshd` на порту `SSH_PORT` (2222): `ssh -p 2222 fold2@<IP>` (сначала задай пароль: `run passwd fold2`) |
| `docker [stop]` | `dockerd`; сеть `DOCKER_NET`: `host` (по умолчанию, надёжно) или `bridge`. `stop` ждёт до 30 с, пока `dockerd` остановит контейнеры |
| `llama [stop\|log]` | `llama-server` на `0.0.0.0:LLAMA_PORT` (8080), веб-интерфейс и OpenAI API |
| `autostart on\|off` | запуск при загрузке через Magisk `service.d`: `start` + то, что включено в `AUTO_*`; `on` ставит и кнопку (`module on`) |
| `module on\|off` | кнопка в Magisk: Модули → «Fold2: Debian (компьютер)» → «Действие» = `x11` + `status` (модуль `/data/adb/modules/fold2`, ничего не монтирует) |
| `backup <файл\|-> [models]` | копия Debian и `debian.conf` в `.tar.gz` (`-` — в stdout); работающий Debian останавливает на время копии и запускает снова; без Docker, кэша apt, `/tmp` и моделей llama (`models` — с ними). См. «Копия Debian» |
| `restore <файл\|->` | вернуть Debian из копии (`-` — из stdin); если Debian уже есть — отказ (сначала `remove yes`) |
| `remove [yes]` | удалить Debian, автозапуск и кнопку (см. «Удалить»); без `yes` — показать, что удалится |
| `battery [N\|off]` | предел заряда `N` % (50–99) — для телефона, который всегда на зарядке (см. «Сервер 24/7»); без `N` — показать |
| `bootlog [ls]` | сохранить логи прошлой загрузки (почему телефон перезагрузился) в `/data/local/fold2/bootlogs/`; `ls` — список с причинами |

Пароль пользователя после установки не задан: `su -mm -c "sh /data/local/fold2/debian.sh run passwd fold2"`.
Пользователь создаётся с UID 8000 (не 1000: в Android это `system`, и `kill -1`/`pkill -u` от такого пользователя
убили бы `system_server`); он в группах `aid_media_rw` и др. — по правам `/data/media/0` (группа media_rw) этого
должно хватать для `/sdcard` без root (на телефоне не проверено). Файлы, созданные в `/sdcard` из Debian, Android
(галерея и т.п.) увидит после пересканирования медиа.

## Настройки — `/data/local/fold2/debian.conf`
Создаётся при `install`. Это файл Android (вне Debian): править `su -c "/data/adb/magisk/busybox vi /data/local/fold2/debian.conf"`
или просто дописать строку — последняя побеждает: `su -c "echo LLAMA_DEVICE=Vulkan0 >> /data/local/fold2/debian.conf"`.

| Переменная | По умолчанию | Что значит |
|---|---|---|
| `DEB_USER` | `fold2` | пользователь для `shell`, `x11` |
| `SSH_PORT` | `2222` | порт `sshd` |
| `DOCKER_NET` | `host` | `host` — контейнеры в сети телефона, без iptables; `bridge` — обычные сети Docker (iptables legacy, правила маршрутизации Android добавляет скрипт; после смены сети — снова `debian.sh docker`) |
| `DOCKER_STORAGE` | пусто | драйвер хранения Docker; пусто — выбирает `dockerd` (`overlay2`); `vfs` — если `overlay2` не заработает (медленно, много места) |
| `DOCKER_IMG_GB` | `32` | данные Docker (`/var/lib/docker`) в образе ext4 такого размера, смонтированном через loop: `overlay2` не берёт `/data` (f2fs с шифрованием и casefold) как верхний слой. Место на `/data` занимается по мере заполнения; `0` — прямо в `/data` |
| `LLAMA_HF` | `unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_0` | модель с Hugging Face, качается при первом запуске в `/var/lib/llama` |
| `LLAMA_MODEL` | пусто | путь к `.gguf` внутри Debian (например `/sdcard/models/x.gguf`), тогда `LLAMA_HF` не нужен |
| `LLAMA_PORT` | `8080` | порт `llama-server` (NPU-сервер из `npu.sh` — 8081, оба могут работать сразу) |
| `LLAMA_THREADS` | `4` | потоков |
| `LLAMA_CPUS` | `4-7` | ядра для `taskset -c` (большие ядра SD865+) |
| `LLAMA_CTX` | `8192` | контекст |
| `LLAMA_DEVICE` | `none` | `none` — CPU; `Vulkan0` — Adreno 650 через Turnip (экспериментально) |
| `LLAMA_NGL` | `0` | слоёв на GPU (с `Vulkan0`, например `99`) |
| `LLAMA_API_KEY` | пусто | если задан — сервер требует ключ (передаётся файлом `/run/llama-api-key`, в `ps` не виден) |
| `LLAMA_ARGS` | пусто | любые дополнительные ключи `llama-server` |
| `X11_SELINUX_PERMISSIVE` | `1` | `x11` переводит SELinux в Permissive до перезагрузки — без этого Termux:X11 не видит сокет из chroot; `0` — не трогать |
| `AUTO_X11` | `0` (`pc_install_debian.sh` ставит `1`) | рабочий стол XFCE при загрузке (`autostart on`), если стоит Termux:X11: X-сервер ждёт, пока откроют приложение |
| `AUTO_SSH` / `AUTO_DOCKER` / `AUTO_LLAMA` | `1` / `0` / `0` | что запускать при загрузке (`autostart on`). Если `LLAMA_MODEL` в `/sdcard`, llama ждёт первой разблокировки телефона (до неё `/sdcard` зашифрован); без `LLAMA_MODEL` (модель с Hugging Face) — ждёт сеть, до 10 минут. Нет `debian.conf` — как по умолчанию. Лог — `/data/local/fold2/autostart.log` |
| `BATT_LIMIT` | пусто | `50`–`99`: при загрузке (`autostart on`) поставить предел заряда и раз в 10 минут проверять, не переписала ли его система; пусто — не трогать |
| `AUTO_BOOTLOG` / `BOOTLOG_KEEP` | `1` / `5` | при загрузке сохранять логи прошлой загрузки (`bootlog`), хранить последние 5 |

## GPU: Turnip и Zink
`turnip-kgsl-debian13-arm64.tar.xz` — Mesa 26.2.6 (`freedreno` Vulkan с KGSL, собрано в CI под Debian 13) в
`/opt/turnip`. `/etc/profile.d/fold2-gpu.sh` задаёт `VK_ICD_FILENAMES`, `TU_DEBUG=noconform` (в Mesa 26.2.6 есть,
`tu_util.cc`: разрешает multiview без аппаратной поддержки — нужно для Vulkan 1.1+ на Adreno 650) и
`MESA_VK_WSI_DEBUG=sw` (кадры показываются через CPU — надёжно в Termux:X11). Обе можно переопределить: например
`MESA_VK_WSI_DEBUG= vkcube` — попробовать показ через DRI3 без копирования (по описанию Termux:X11 DRI3 поддерживает;
с Turnip/KGSL не проверено).
```bash
. /etc/profile.d/fold2-gpu.sh; vulkaninfo --summary      # в Debian: должен быть Turnip Adreno (TM) 650
zink glxgears                                           # OpenGL поверх Vulkan (Zink + Turnip)
```
llama.cpp на GPU: `LLAMA_DEVICE=Vulkan0`, `LLAMA_NGL=99` в `debian.conf`, затем `debian.sh llama stop; debian.sh llama`.
Будет ли это быстрее CPU на Adreno 650 — не проверено.

## Ядро f2q и Linux
Проверено по конфигу ядра из `f2q-3` (`/proc/config.gz` извлечён из `boot.img`, Linux 4.19.325):
- **есть:** namespaces (net, pid, ipc, uts, user), cgroups v1 (cpu, cpuacct, cpuset, memory, devices, freezer,
  pids, blkio), overlayfs, veth, bridge, macvlan, vxlan, tun, iptables (NAT, MASQUERADE, conntrack, addrtype),
  seccomp, fuse, loop, zram, KGSL (GPU), FastRPC и ION (NPU);
- **нет:** `nf_tables` (поэтому `iptables-legacy`), NAT для IPv6 (в Docker `ip6tables: false`), **SysV IPC**
  (как и положено в Android): `shmget`/`semget` дают «Function not implemented» — не запустится, например,
  PostgreSQL (и образ `postgres` в Docker), X-программы с MIT-SHM обычно сами переходят на отрисовку без него; `binfmt_misc` —
  только arm64-образы, amd64 через qemu не пойдут (отдельную программу x86-64 можно запустить явно:
  `qemu-x86_64-static ./prog` или `box64 ./prog`, но её дочерние x86-процессы — нет); CFS bandwidth — `docker run --cpus` не работает (`--memory`
  работает); IPVS (Swarm), btrfs, squashfs (snap), KVM.
- **cpuset**: Android монтирует его с `noprefix` (файлы `cpus` вместо `cpuset.cpus`), с ним `runc` падает
  («cpuset.cpus: no such file or directory», известная проблема Docker на Android). `debian.sh` его в chroot не
  монтирует (`runc` пропускает несмонтированные контроллеры, кроме devices) — Docker без `--cpuset-cpus`.
- **overlay2 и `/data`**: overlayfs ядра 4.19 не принимает верхний слой на f2fs с шифрованием/casefold, поэтому
  `debian.sh docker` при первом запуске создаёт `/var/lib/docker.img` (ext4, `DOCKER_IMG_GB`) и монтирует его в
  `/var/lib/docker`; `stop` размонтирует и отцепляет loop. Если в `/var/lib/docker` уже есть данные, образ не создаётся.
- **корень chroot — точка монтирования**: `debian.sh start` делает `mount --bind` каталога Debian на самого себя
  (private). Без этого `docker pull` падает с «failed to register layer: remount /, flags: 0x84000: invalid argument»
  (dockerd и runc делают `mount --make-rslave /`, см. termux-packages#18359). Если Debian смонтирован старой версией
  скрипта, `start` попросит `stop` и `start` заново.

## llama.cpp
`llama-debian-arm64.tar.xz` — llama.cpp **v0.8.0** (CPU + Vulkan, `-march=armv8.2-a+dotprod+fp16` под Kryo 585),
в `/opt/llama.cpp/bin`, ссылки в `/usr/local/bin` (`llama-cli`, `llama-server`, `llama-bench`, …). Если архива нет,
`setup_in_chroot.sh` собирает тот же тег на телефоне (`GGML_NATIVE=ON`, 15–30 минут).
Модели, скачанные `debian.sh llama` (`-hf`), лежат в `/data/local/fold2/debian/var/lib/llama` — `npu.sh` ищет
модели и там.

## Файлы
- `pc_install_debian.sh` — установка с ПК (выше).
- `phone/debian.sh` — управление Debian на телефоне (кладётся в `/data/local/fold2/`).
- `phone/setup_in_chroot.sh` — настройка внутри Debian (можно повторять: `debian.sh run bash /root/setup_in_chroot.sh fold2`).
- `phone/backup_efs.sh` — копия разделов с IMEI и ключами (только чтение); `pc_install_debian.sh` запускает его сам.
- `pc_check_phone.sh`, `phone/check_phone.sh` — проверка телефона после прошивки (выше); установщик запускает её сам.
- `pc_backup_debian.sh` — копия Debian на ПК и возврат её на телефон (см. «Копия Debian»).
- `test/` — автотесты (идут в CI при каждом изменении, см. ниже): `test_phone.sh`, `test_pc_install.sh`, `e2e_chroot.sh`.

## Что проверено
- **Автоматически при каждом изменении** (CI `tools.yml`; релиз `tools-N` выходит, только если всё прошло):
  - `test/test_phone.sh` — `debian.sh` (`battery`, температуры в `status`, `bootlog`, автозапуск и его цикл предела
    заряда, автозапуск без `debian.conf`, ожидание сети перед `llama` с Hugging Face, `install` продолжает оборванную
    установку и отказывает при законченной, справка, отказ без root, кнопка в Magisk (`module on/off`, ставится с `autostart on`, убирается `remove`),
    `x11` (запущенный рабочий стол не перезапускается, `stop`, `status`), автозапуск с `AUTO_X11=1` (без Termux:X11 —
    без рабочего стола), `remove`: без `yes` ничего не удаляет, не удаляет, пока что-то смонтировано
    или работает в chroot, `stop` с оставшимся монтированием — код 1), `backup`/`restore` (в копии нет содержимого
    `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, образа и данных Docker, `.deb` из кэша apt и моделей — с `models` есть;
    `setuid` в копии, `0600`; `backup -` — в stdout только архив; отказ при смонтированном `/sdcard` (stdout пуст),
    внутрь Debian, поверх Debian, для битого и чужого архива — Debian наполовину не появляется; `debian.conf` из копии,
    прежний сохраняется; из stdin), `check_phone.sh` (всё работает / всё сломано /
    без root, Magisk: нет приложения / нет `su` / не сделана доп. настройка, в выводе нет IMEI, серийника, MAC, SSID, ICCID, IMSI, номера и почты; список опций ядра = `docker.config`),
    `backup_efs.sh` (состав архива, sha256, `0600`, недочитанный раздел, нет
    разделов), `npu.sh` (уровень отладки, поиск модели, `test`: коды 0/3/1 и снятие зависшего `f2q-bench` по таймауту, справка). Каждый тест — в **mksh** под именем `sh` (это
    `/system/bin/sh` Android) и в **busybox ash** (им Magisk запускает автозапуск), утилиты — busybox; и третий раз
    как в **Android 16**: mksh + **toybox 0.8.12** с конфигурацией AOSP `android16-release` и только теми командами,
    что есть в `/system/bin` Android 16 (нет `awk`/`ip` toybox — они из других пакетов, берутся из busybox); `/sys`, `/proc`,
    `/dev/block` подменены каталогом.
  - `test/test_pc_install.sh` — установщик с заглушками `adb`/`curl`: первая установка, рабочий стол (`AUTO_X11`
    1/0/уже в `debian.conf`/неверный, не запустился, Debian не встал), root (нет приложения Magisk —
    ставится из `f2q-N` или официальный с `digest`, без суммы / с неверной суммой — не ставится; доп. настройка с
    перезагрузкой; Shell разрешили не сразу; нет `su`; так и не разрешили), проверка телефона в отчёте
    (`SKIP_CHECK=1`, проверка не прошла), `pc_check_phone.sh` (с root / без / ошибка / не разрешена отладка / нет
    телефона, CRLF), повторный запуск, копия EFS
    (битая, не сделалась), LOW/MID/HIGH и ответы на вопрос (через псевдотерминал, локали C и UTF-8), блокировка экрана,
    неверные имя и `BATT_LIMIT`, нет телефона / два устройства / нет root, ошибка установки (NPU и отчёт всё равно,
    код 1) и её продолжение при следующем запуске, неверная sha256, устаревший кэш, скрипты с CRLF; выбор релиза
    `tools-N` с наибольшим номером (заглушка отдаёт `tools-9` раньше `tools-10`, как API GitHub, и больше 100 релизов —
    новый только на 2-й странице), то же для `fetch` из `setup_in_chroot.sh`; итог проверки NPU (DSP работает / не
    открылся / не пройдена), телефон перезагрузился во время проверки NPU или ненадолго пропал из adb; перезагрузка в LOW при медленном выключении (уровень не читается со старой загрузки) и
    несработавший `reboot`; предел заряда, уже заданный в `debian.conf`; API GitHub не ответил, нет Termux:X11, модель
    не скачалась, пакет NPU не распаковался, `adb devices` с ошибкой, старый `adb` (1.0.32 — скачивается свежий);
    удалённый Termux:X11 ставится снова; `pc_backup_debian.sh` (архив через `exec-out`, сообщения и код — файлами на
    телефоне; проверка, `.sha256`, `0600`, установленные скрипты не меняются; `models`; ошибка на телефоне, оборванный
    поток — битый файл удаляется; нет Debian / root) и `restore`/`RESTORE` (вместо установки: копия на телефон и
    убирается, Termux:X11, ssh, автозапуск, NPU, отчёт, пользователь из копии; отказ: Debian уже есть, мало места,
    `.sha256` не сходится, чужой или обрезанный архив, нет файла).
  - `test/e2e_chroot.sh` — на настоящем **arm64** Linux с root (не телефон: другое ядро, нет SELinux Android):
    `debian.sh install` с образом trixie arm64 и настоящим `setup_in_chroot.sh` (apt, пакеты, пользователь UID 8000,
    Turnip и llama.cpp из этой же сборки), вход по `ssh` по ключу и `sudo`, `llama-server` с маленькой моделью и ключом
    API (без ключа — 401, ключа нет в `ps`), `status`, `stop` (монтирований и процессов 0), повторные `start`/`stop`,
    продолжение оборванной установки (`install -` без rootfs снова проходит `setup_in_chroot.sh`), `remove yes`
    (в `$R/sdcard` подмонтирована папка с файлом — после удаления файл цел, монтирований 0, `debian.conf` остался),
    `backup -` работающего Debian (остановил и снова поднял `sshd`; образа Docker и содержимого `/proc` в копии нет),
    `remove yes` и `restore` из копии: файлы пользователя, владельцы `8000:8000`, `setuid` у `sudo`, file capabilities
    (`setcap`), `/tmp` `1777`, вход по ssh тем же ключом и `sudo`, повторный `restore` — отказ, автозапуск так, как его выполняет Magisk (busybox ash в режиме standalone: `mount`,
    `chroot` и т.д. — из busybox): поднимает Debian и `sshd`, собирает `bootlog`, после него вход по ssh.
  - NPU (`npu/`): ядро HVX в `qemu-hexagon`, заглушка DSP, `f2q-bench` и ggml-бэкенд на x86 — ещё и с **ASan + UBSan**
    (и TSan для `f2q-bench`): ошибок памяти, неопределённого поведения, утечек и гонок нет.
  - Итоги (сколько проверок прошло) — в описании каждого релиза `tools-N`.
- Сборка в CI (`.github/workflows/tools.yml`, задачи «Turnip Debian 13 arm64» и «llama.cpp Debian 13 arm64»,
  контейнер `debian:trixie` на arm64): Mesa собирается с этими опциями, ICD и `50_mesa.json` на месте; llama.cpp
  собирается, бинарники запускаются (`--version`) в Debian 13; архивы попадают в релиз `tools-N`.
- Ссылки, которые качают скрипты: rootfs trixie arm64 и его `SHA256SUMS`, Termux:X11 nightly, модели на Hugging Face.
- `debian.sh` на ПК (x86, rootfs Debian 13 amd64, `busybox ash` из Magisk вместо `sh`, заглушка вместо тяжёлого
  `setup_in_chroot.sh`): `install` (распаковка busybox tar, debian.conf, монтирование, запуск setup в chroot),
  `status`, `run`, `ssh`, `llama` (сервер отвечает на `/health`), `llama stop`, `autostart on/off`, `stop`
  (все процессы chroot завершены, монтирований 0). `llama`/`llama stop` не трогают `llama-server` из `npu.sh`,
  работающий вне chroot.
- Полная установка (`debian.sh install` с настоящим `setup_in_chroot.sh`) в chroot Debian 13 **amd64** на ПК:
  ставятся 316 пакетов (XFCE, Firefox, Docker 26.1.5, сборочные), службы при установке не стартуют, iptables
  переключается на legacy, пользователь с UID 8000 в группах sudo/docker/aid_inet/aid_media_rw/…, Turnip и llama.cpp качаются из релиза
  `tools-N` и распаковываются, `debian.sh stop` размонтирует всё. Все имена пакетов есть в индексе trixie **arm64**.
- `daemon.json` для `host`/`bridge` и с `DOCKER_STORAGE` — валидный JSON, `dockerd` 26.1.5 его принимает
  (дальше в песочнице упирается в cgroup v2 хоста, на телефоне v1).
- Docker в том же chroot amd64 (cgroup v2 хоста подложен вручную, т.к. v1 в песочнице не смонтировать):
  `debian.sh docker` создаёт образ ext4 и монтирует его (loop как на Android, `/dev/block/loopN`), `dockerd` выбирает
  `overlay2` на `extfs`, `docker run hello-world` и `debian:trixie-slim` работают. До bind корня `docker pull`
  падал с «remount /, flags: 0x84000» — так было бы и на телефоне. `debian.sh stop`: монтирований 0, loop отцеплен.
- Монтирование cgroup на примере `/proc/mounts` Android: Android-иерархии подключаются bind, cpuset (noprefix)
  пропускается, devices/freezer/pids монтируются заново.
- `shellcheck` для всех скриптов чистый.
- С tools-14 (локально: `busybox ash`, `unshare -m` с `mount --make-rshared /` как у Android, rootfs Debian 13 amd64):
  старый `debian.sh start` монтировал `tmpfs` и `devpts` и в «Android» `/dev` (`/dev/shm` и `/dev/pts` по два раза),
  новый — нет (`$R/dev`, `$R/sdcard` — `master`, т.е. slave); `stop` — монтирований 0. Автозапуск (сгенерированный
  `service.d`-скрипт, `getprop` подменён) ждёт появления модели и запускает llama; ключ — файлом `0600`, в командной
  строке `--api-key-file`; маска ядер, которых нет, — запуск без `taskset`; `docker stop` ждёт выхода `dockerd`
  (заглушка), упрямый — убивает через 30 с. `pc_install_debian.sh` с заглушками `adb`/`curl`: повторный запуск ничего не
  качает, новый файл в релизе — перекачивает, битый — ошибка sha256, ошибка `debian.sh install` за `| tee` теперь
  останавливает установку, недопустимое имя пользователя отклоняется.
- С tools-15 (тот же стенд, поддельные `/sys` и `/proc`): `battery 80`/`off`/недопустимые значения, строка
  температуры в `status` (максимум по группе датчиков), `bootlog` (повторный запуск в той же загрузке не плодит
  копий, хранятся `BOOTLOG_KEEP` последних, мусор в `BOOTLOG_KEEP` не удаляет всё), автозапуск возвращает
  `BATT_LIMIT`, если предел переписали; `backup_efs.sh` на поддельных разделах: имена в любом регистре, архив `0600`,
  sha256 сходятся, недочитанный раздел — ошибка.
- `pc_install_debian.sh` с tools-16 (заглушки `adb`/`curl`): копия EFS попадает на ПК и удаляется с телефона только при
  совпавшем sha256 (при несовпадении — остаётся на телефоне, на ПК битая удаляется); вторая копия не делается; уровень
  MID/HIGH → вопрос, после «да» перезагрузка и повторная проверка, «н»/«нет»/«n» — без перезагрузки (и в локали C),
  без терминала — не спрашивает; не LOW → `npu.sh test` пропускается; уровень из `/proc/cmdline`, если `getprop`
  пуст; ожидание разблокировки; повторный запуск при готовом Debian — только обновление скриптов и автозапуска, модель
  того же размера не копируется; `BATT_LIMIT=80` в `debian.conf`; отчёт собирается.

## Что НЕ проверено
- **Ничего не запускалось на телефоне**: монтирование, Docker на ядре UN1CA, Termux:X11 из chroot, Turnip на
  KGSL Adreno 650, автозапуск, `backup`/`restore` (busybox из Magisk; метки SELinux файлов после `restore` — те же,
  что после `install`: файлы так же создаёт root в `/data/local/fold2`).
- Docker на самом телефоне: опции ядра на месте (см. «Ядро f2q и Linux»), но запуск не проверен. Если `bridge` не
  заработает — оставь `DOCKER_NET=host`; если `docker run` ругается на overlay — `DOCKER_STORAGE=vfs`. Монтирование
  образа ext4 через toybox `mount` (сам вызывает `losetup -fs`) на Android не проверено.
- Vulkan в Termux:X11 идёт через CPU-копирование кадров (`MESA_VK_WSI_DEBUG=sw`) — для игр медленно, для
  вычислений (llama.cpp) не мешает. DRI3 (`MESA_VK_WSI_DEBUG=`) не проверен.
- `batt_full_capacity` есть в ядре UN1CA (`drivers/battery_v2/sb_full_soc.c`), но как с ним уживается «Защита
  аккумулятора» One UI 8, не проверено. Имена датчиков температуры (`cpu-*-usr`, `gpuss-*-usr`, `q6-hvx-usr`,
  `npu-usr`) — по разбору ядра SM8250, на телефоне не проверены; `status` пропускает то, чего нет.

## Телефон как сервер 24/7 (советы; на телефоне не проверено)
- **Защита аккумулятора**: Настройки → Аккумулятор → Защита аккумулятора → «Максимум 80 %» — для телефона, который
  всё время на зарядке. Или `debian.sh battery 80` (сразу) и `BATT_LIMIT=80` в `debian.conf` (при каждой загрузке).
  По коду ядра (`sb_full_soc.c`): на 80 % зарядка выключается, а телефон питается от адаптера мимо батареи
  (`CHARGING_OFF`), с 78 % снова заряжается; `off` — без предела. **Не** включай `batt_slate_mode` (под кабелем
  телефон работает от батареи и разряжает её) и `store_mode`. Если в настройках выбран другой режим защиты, система
  может переписать предел — автозапуск вернёт `BATT_LIMIT` и запишет это в `autostart.log`.
- **Уровень отладки LOW** (`getprop ro.boot.debug_level` = `0x4f4c`): при MID/HIGH любая паника ядра (и падение cDSP,
  см. `npu/README.md`) оставляет телефон в Upload mode до нажатия кнопок, при LOW — он просто перезагружается.
  Поставить LOW: `su -c "reboot debug0x4f4c"` (по коду ядра `sec_debug.c`, на телефоне не проверено).
- **Почему перезагрузился**: `debian.sh bootlog` (и при каждой загрузке с `autostart on`) копирует pstore
  (`/sys/fs/pstore`), Samsung `/proc/last_kmsg` и `/proc/reset_*` и `logcat -L` (лог прошлой загрузки) в
  `/data/local/fold2/bootlogs/<время>-<boot id>/`; `debian.sh bootlog ls` — причины по загрузкам.
- **Бэкап EFS — один раз, до экспериментов**: `pc_install_debian.sh` делает его сам (на ПК в `~/fold2-backup/`).
  Вручную: `adb push linux/phone/backup_efs.sh /data/local/tmp/`, затем
  `adb shell su -c "sh /data/local/tmp/backup_efs.sh"` и `adb pull /data/local/tmp/fold2-efs-<время>.tar.gz`.
  Скрипт только читает разделы `efs`, `sec_efs`, `modemst1/2`, `fsg`, `fsc`, `mdm1m9kefs1/2/3/c` (EFS модема SDX55),
  `persist`, `steady`, `param` и др. и сверяет размер и sha256. В архиве IMEI и ключи — храни его как пароль и удали
  с телефона после копирования. Проверено только на поддельных разделах.
- **Не засыпать** (советы, не проверено): `echo fold2 > /sys/power/wake_lock` (держит CPU, снять —
  `echo fold2 > /sys/power/wake_unlock`), `dumpsys deviceidle disable`; Wi-Fi без энергосбережения —
  `iw dev wlan0 power_save off`, если `iw` есть (в Debian: `apt install iw`), — до перезагрузки.
- **Phantom process killer** (Android 12+) убивает дочерние процессы приложений, например запущенные в Termux:
  `adb shell settings put global settings_enable_monitor_phantom_procs false`. Службы `debian.sh` (их запускает
  root через `su`/Magisk `service.d`, не приложение) он, судя по коду Android, не трогает; Freecess Samsung
  замораживает приложения, а не процессы root (по разбору, не проверено).
- **cpuset**: Android может держать процессы `su`/adb в урезанном cpuset (только малые ядра). `debian.sh` переносит
  себя в корневые `/dev/cpuset`, `/dev/cpuctl`, `/dev/stune`; `status` показывает cpuset служб. Если
  `taskset -c $LLAMA_CPUS` всё равно не работает — llama стартует без привязки (с предупреждением).
- **Звук из Debian** (не проверено): PulseAudio из Termux — `pkg install pulseaudio`, в
  `$PREFIX/etc/pulse/default.pa` раскомментировать `load-module module-aaudio-sink` (или оставить `module-sles-sink`),
  `pulseaudio --start --exit-idle-time=-1 --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1"`;
  в Debian — `export PULSE_SERVER=tcp:127.0.0.1:4713` (сеть у chroot общая с Android). Прямой ALSA мешает audioserver.
- **DeX + Termux:X11**: в настройках Termux:X11 включи перехват системных сочетаний (Intercept system shortcuts /
  `dexMetaKeyCapture`), иначе Win/Alt+Tab забирает DeX.
- Без монитора: `scrcpy --new-display=1920x1080` с ПК (scrcpy 3.x) создаёт отдельный виртуальный экран — можно
  открыть на нём Termux:X11.
- Монтирования: `/dev` и `/data` у Android «shared», поэтому `$R/dev` и `$R/sdcard` после bind переводятся в `rslave` —
  изменения Android видны в Debian, а `/dev/shm`, `/dev/pts` и прочее, смонтированное внутри, в Android не попадает
  (до этой правки попадало — проверено на стенде, см. ниже).

## Удалить
```bash
su -mm -c "sh /data/local/fold2/debian.sh remove yes"   # Debian: автозапуск off, stop, удаление
su -mm -c "rm -rf /data/local/fold2 /data/local/tmp/fold2-npu"   # всё остальное (debian.conf, bootlog, NPU)
```
`remove` выключает автозапуск, останавливает Debian и удаляет `/data/local/fold2/debian`, только если **ничего не
осталось смонтированным** и в chroot ничего не работает (`debian.conf` и `bootlog` остаются). Иначе — отказ и
совет перезагрузить телефон: внутри смонтированы `/sdcard` и `/dev`, `rm -rf` прошёлся бы по твоим файлам. Поэтому
**не удаляй Debian руками `rm -rf`, пока `status` показывает монтирования**. `stop` тоже теперь выходит с кодом 1,
если что-то осталось смонтированным.
