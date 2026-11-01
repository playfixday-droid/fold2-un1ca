# linux/ — Debian 13 (trixie) в chroot на Fold2: XFCE в DeX, Docker, Vulkan (Turnip), llama.cpp

Полноценный Debian 13 arm64 рядом с Android (chroot, без эмуляции): рабочий стол XFCE через Termux:X11 (окно
уводится на монитор в DeX), Docker, `ssh`, Vulkan на Adreno 650 через Turnip (Mesa, KGSL), llama.cpp на CPU или
Vulkan. NPU (cDSP) — отдельно, в Android: см. [`npu/README.md`](../npu/README.md).

> **На телефоне не запускалось.** Проверено только то, что перечислено в «Что проверено».

## Что нужно
- Прошивка `f2q-N` из Releases с root: AP уже содержит boot с **Magisk v31.1**; после прошивки поставь
  `Magisk-v31.1.apk` из того же релиза. Вернуть boot без root — `BOOT_noroot_f2q.tar.md5` в Odin (слот AP).
- ПК с `adb` (platform-tools) и `curl`, USB-отладка, интернет на ПК и телефоне. ~8 ГБ свободного места на телефоне (Debian с XFCE/Docker ~4 ГБ, модели 1–2.5 ГБ).

## Установка одной командой (с ПК)
```bash
bash linux/pc_install_debian.sh            # пользователь Debian по умолчанию fold2
bash linux/pc_install_debian.sh ivan       # свой пользователь
SKIP_NPU=1 bash linux/pc_install_debian.sh # без NPU;  SKIP_DEBIAN=1 - только NPU;  SKIP_MODEL=1 - без модели для NPU
```
При первом `su` на внешнем экране появится запрос Magisk — разреши **Shell**. Скрипт:
1. берёт свежий rootfs Debian trixie arm64 с images.linuxcontainers.org и сверяет SHA256;
2. из последнего релиза `tools-N` этого репозитория качает `turnip-kgsl-debian13-arm64.tar.xz` и
   `llama-debian-arm64.tar.xz` (если их нет — `setup_in_chroot.sh` скачает сам или соберёт llama.cpp на телефоне);
3. ставит Termux:X11 (nightly `termux-x11-universal-debug.apk`);
4. на телефоне: `debian.sh install` (распаковка + `setup_in_chroot.sh`: XFCE, Firefox, Docker, Vulkan, сборочные
   пакеты, пользователь с `sudo` без пароля) — 10–30 минут, лог `/data/local/fold2/install.log`;
   затем `debian.sh ssh` и `debian.sh autostart on`;
5. NPU: `f2qdsp-android-arm64.tar.xz` → `/data/local/tmp/fold2-npu`, модель `Qwen3-1.7B-Q4_0.gguf` →
   `/sdcard/models`, `npu.sh test` (другая модель: `NPU_MODEL_URL=...`; папка загрузок: `WORK=...`).

Повторный запуск безопасен: скачанное берётся из `linux/fold2-dl/` (файлы из `tools-N` и rootfs сверяются с `SHA256SUMS`
их релиза; устаревший или битый файл качается заново), а `install` откажется ставить поверх готового
Debian (удалить: `debian.sh stop && rm -rf /data/local/fold2/debian`).

## Команды на телефоне
Всё от root, лучше через `su -mm` (глобальный mount namespace; скрипт и сам переходит в него через `nsenter`):
```bash
adb shell
su -mm -c "sh /data/local/fold2/debian.sh <команда>"
```

| Команда | Что делает |
|---|---|
| `install <rootfs.tar.xz> [пользователь]` | распаковать Debian в `/data/local/fold2/debian` и выполнить `setup_in_chroot.sh` |
| `start` / `stop` / `status` | смонтировать (`/proc`, `/sys`, `/dev`, `/dev/pts`, `/dev/shm`, `/run`, `/sdcard`, cgroup) / завершить процессы chroot (сначала корректно `dockerd`) и размонтировать / что запущено (и в каком cpuset), батарея, IP |
| `shell [пользователь]` | войти (по умолчанию `DEB_USER`; `shell root` — root) |
| `run <команда…>` | выполнить команду в Debian от root, например `run passwd fold2`, `run apt install gimp` |
| `x11` | XFCE в Termux:X11; в DeX окно Termux:X11 перетащи на монитор и разверни |
| `ssh` | `sshd` на порту `SSH_PORT` (2222): `ssh -p 2222 fold2@<IP>` (сначала задай пароль: `run passwd fold2`) |
| `docker [stop]` | `dockerd`; сеть `DOCKER_NET`: `host` (по умолчанию, надёжно) или `bridge`. `stop` ждёт до 30 с, пока `dockerd` остановит контейнеры |
| `llama [stop\|log]` | `llama-server` на `0.0.0.0:LLAMA_PORT` (8080), веб-интерфейс и OpenAI API |
| `autostart on\|off` | запуск при загрузке через Magisk `service.d`: `start` + то, что включено в `AUTO_*` |

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
| `AUTO_SSH` / `AUTO_DOCKER` / `AUTO_LLAMA` | `1` / `0` / `0` | что запускать при загрузке (`autostart on`). Если `LLAMA_MODEL` в `/sdcard`, llama ждёт первой разблокировки телефона (до неё `/sdcard` зашифрован). Лог — `/data/local/fold2/autostart.log` |

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
  только arm64-образы, amd64 через qemu не пойдут; CFS bandwidth — `docker run --cpus` не работает (`--memory`
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

## Что проверено
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

## Что НЕ проверено
- **Ничего не запускалось на телефоне**: монтирование, Docker на ядре UN1CA, Termux:X11 из chroot, Turnip на
  KGSL Adreno 650, автозапуск.
- Docker на самом телефоне: опции ядра на месте (см. «Ядро f2q и Linux»), но запуск не проверен. Если `bridge` не
  заработает — оставь `DOCKER_NET=host`; если `docker run` ругается на overlay — `DOCKER_STORAGE=vfs`. Монтирование
  образа ext4 через toybox `mount` (сам вызывает `losetup -fs`) на Android не проверено.
- Vulkan в Termux:X11 идёт через CPU-копирование кадров (`MESA_VK_WSI_DEBUG=sw`) — для игр медленно, для
  вычислений (llama.cpp) не мешает. DRI3 (`MESA_VK_WSI_DEBUG=`) не проверен.
- Имена файлов батареи в sysfs (`batt_full_capacity` и т.п.) на Fold2 с One UI 8 не проверены — `status` просто
  пропустит то, чего нет.

## Телефон как сервер 24/7 (советы; на телефоне не проверено)
- **Защита аккумулятора**: Настройки → Аккумулятор → Защита аккумулятора → «Максимум 80 %» — для телефона, который
  всё время на зарядке. `debian.sh status` показывает заряд, температуру и (если ядро даёт) `batt_full_capacity`.
- **Phantom process killer** (Android 12+) убивает дочерние процессы приложений, например запущенные в Termux:
  `adb shell settings put global settings_enable_monitor_phantom_procs false`. Службы `debian.sh` (их запускает
  root через `su`/Magisk `service.d`, не приложение) он, судя по коду Android, не трогает; Freecess Samsung
  замораживает приложения, а не процессы root (по разбору, не проверено).
- **cpuset**: Android может держать процессы `su`/adb в урезанном cpuset (только малые ядра). `debian.sh` переносит
  себя в корневые `/dev/cpuset`, `/dev/cpuctl`, `/dev/stune`; `status` показывает cpuset служб. Если
  `taskset -c $LLAMA_CPUS` всё равно не работает — llama стартует без привязки (с предупреждением).
- **DeX + Termux:X11**: в настройках Termux:X11 включи перехват системных сочетаний (Intercept system shortcuts /
  `dexMetaKeyCapture`), иначе Win/Alt+Tab забирает DeX.
- Без монитора: `scrcpy --new-display=1920x1080` с ПК (scrcpy 3.x) создаёт отдельный виртуальный экран — можно
  открыть на нём Termux:X11.
- Монтирования: `/dev` и `/data` у Android «shared», поэтому `$R/dev` и `$R/sdcard` после bind переводятся в `rslave` —
  изменения Android видны в Debian, а `/dev/shm`, `/dev/pts` и прочее, смонтированное внутри, в Android не попадает
  (до этой правки попадало — проверено на стенде, см. ниже).

## Удалить
```bash
su -mm -c "sh /data/local/fold2/debian.sh autostart off; sh /data/local/fold2/debian.sh stop"
su -mm -c "sh /data/local/fold2/debian.sh status"   # должно быть «монтирований: 0»
su -mm -c "rm -rf /data/local/fold2"
```
**Не удаляй, пока `status` показывает монтирования**: внутри смонтированы `/sdcard` и `/dev`, `rm -rf` прошёлся бы
по твоим файлам. Перезагрузка телефона тоже всё размонтирует (если автозапуск выключен).
