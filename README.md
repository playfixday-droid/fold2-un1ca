# fold2-un1ca — One UI 8 (Android 16) для Galaxy Z Fold2 5G SM-F916B

Порт [UN1CA](https://github.com/salvogiangri/UN1CA) на Fold2 (f2q) с мёртвым внутренним экраном:
внешний экран основной во всех положениях, DeX по USB-C, ядро UN1CA SM8250 + Docker.
**На телефоне ещё не запускалось.** Собрано из набора fold2-kit v0.8 (сверено со стоком F916BXXS7KXH1).

## Как собрать
Сборка идёт сама на GitHub Actions при изменении `build.conf` или `target/` (или Actions → Build f2q → Run workflow).
Занимает 2–4 часа. Готовое — в **Releases** (`f2q-<номер>`): AP для Odin частями < 2 ГБ, ядра, SHA256SUMS.
Если сборка упала — появится **issue** с ошибкой и концом лога.

Настройки — `build.conf`: режим ядра (`dual`/`cover`), камера (`CAMERA_MASS`), версия UN1CA (`latest`/`tested`).

## Как прошить (только F916B на прошивке F916BXXS7KXH1, загрузчик разблокирован)
```bash
cat AP_f2q_un1ca.tar.md5.part* > AP_f2q_un1ca.tar.md5 && sha256sum -c --ignore-missing SHA256SUMS
sudo odin4 -a AP_f2q_un1ca.tar.md5 -b BL_F916B....tar.md5 -c CP_F916B....tar.md5 -s CSC_OXM_F916B....tar.md5
```
CSC (не HOME_CSC) — данные сотрутся, это обязательно при переходе на One UI 8.
Откат — полный сток F916BXXS7KXH1 через Odin. Загрузчик (BL) сборка не трогает, Download Mode остаётся.

## Состав
- `target/f2q/` — цель UN1CA (config, overlay, патчи, ядро-патчи, инструменты). Статус и что проверить: `target/f2q/TODO.md`.
- `.github/workflows/build-f2q.yml` — ядро → UN1CA → Odin AP → Release.
