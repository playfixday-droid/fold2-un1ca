# fold2-un1ca — One UI 8 (Android 16) для Galaxy Z Fold2 5G SM-F916B

Порт [UN1CA](https://github.com/salvogiangri/UN1CA) на Fold2 (f2q) с мёртвым внутренним экраном:
внешний экран основной во всех положениях, DeX по USB-C, ядро UN1CA SM8250 + Docker.
**На телефоне ещё не запускалось.** Собрано из набора fold2-kit v0.8 (сверено со стоком F916BXXS7KXH1).

## Как собрать
Сборка идёт сама на GitHub Actions при изменении `build.conf` или `target/` (или Actions → Build f2q → Run workflow).
Занимает 2–4 часа. Готовое — в **Releases** (`f2q-<номер>`): AP для Odin частями < 2 ГБ, `BOOT_noroot_f2q.tar.md5`,
`Magisk-v31.1.apk`, ядра, SHA256SUMS.
Если сборка упала — появится **issue** с ошибкой и концом лога.

Настройки — `build.conf`: режим ядра (`dual`/`cover`), камера (`CAMERA_MASS`), версия UN1CA (`latest`/`tested`).

## Как прошить (только F916B на прошивке F916BXXS7KXH1, загрузчик разблокирован)
```bash
cat AP_f2q_un1ca.tar.md5.part* > AP_f2q_un1ca.tar.md5 && sha256sum -c --ignore-missing SHA256SUMS
sudo odin4 -a AP_f2q_un1ca.tar.md5 -b BL_F916B....tar.md5 -c CP_F916B....tar.md5 -s CSC_OXM_F916B....tar.md5
```
CSC (не HOME_CSC) — данные сотрутся, это обязательно при переходе на One UI 8.
Откат — полный сток F916BXXS7KXH1 через Odin. Загрузчик (BL) сборка не трогает, Download Mode остаётся.

## Root (Magisk)
`boot.img` в AP уже пропатчен **Magisk v31.1** (официальный релиз topjohnwu, `KEEPVERITY=false`). После первой
загрузки поставь `Magisk-v31.1.apk` из того же релиза — root готов. Без root: прошей `BOOT_noroot_f2q.tar.md5`
в Odin (слот AP) — это тот же boot без Magisk. Проверено: `magiskboot cpio test` для boot из AP — Magisk
(.backup/.magisk, SHA1 стокового boot совпадает с BOOT_noroot), для BOOT_noroot — сток.

## Debian 13, Docker, llama.cpp и NPU
Нужен root. С ПК: `bash linux/pc_install_debian.sh` — Debian 13 в chroot (XFCE в DeX через Termux:X11, Docker,
ssh, Vulkan Turnip, llama.cpp) и llama.cpp на cDSP (NPU). Подробно: [`linux/README.md`](linux/README.md),
[`npu/README.md`](npu/README.md). Готовые сборки (Turnip, llama.cpp для Debian, f2qdsp для Android) — в
**Releases** `tools-<номер>`; их собирает `.github/workflows/tools.yml` при изменении `linux/` или `npu/`
(прошивку он не трогает). Тоже ещё не запускалось на телефоне.
Для телефона без присмотра: один раз сделать копию EFS (`linux/phone/backup_efs.sh`, только чтение) и проверить
уровень отладки (`getprop ro.boot.debug_level` = `0x4f4c`, LOW) — подробно в `linux/README.md`, «Телефон как сервер 24/7».

## Состав
- `target/f2q/` — цель UN1CA (config, overlay, патчи, ядро-патчи, инструменты). Статус и что проверить: `target/f2q/TODO.md`.
- `.github/workflows/build-f2q.yml` — ядро → UN1CA → Odin AP → Release `f2q-N`.
- `linux/` — Debian 13 в chroot; `npu/` — f2qdsp (llama.cpp на cDSP Hexagon v66).
- `.github/workflows/tools.yml` — сборка и тесты для `linux/` и `npu/` → Release `tools-N`.
- `fold2-kit v0.9` (архив вне репозитория) = инструкции по прошивке и скрипты проверки релиза + `linux/` и `npu.sh`.
