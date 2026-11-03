# f2q: статус

Сверено со стоком F916BXXS7KXH1 (сделано):
- config.sh: TAC, размеры boot/dtbo/cache/super/группы, board, сканер, FINGERPRINT,
  DVFS/SSRM, mDNIe/HDR/HFR/яркость, флаги камеры (вкл. MASS_APP_FLAVOR=false: у стока
  SamsungCamera hal3-flexible_tablet), RECORDALIVE.
- dvfs/siop_model.xml: стоковый термопрофиль siop_f2q_sm8250.xml из SDHMS F916B (был от r8q).
- overlay/: собран из стокового product+vendor RRO и framework-res F916B
  (вырез внешнего экрана стал "основным", power_profile стоковый).
- camera/camera-feature.xml: стоковый файл F916B, *_FULL_RATIO = значения внешнего экрана.
- sff.sh: убраны фолд-фичи (FOLD/HALF_FOLDED/SIP_CONFIG_FOLD_UX).
- patches/cover_display: внешний экран основной во всех положениях (план A),
  плотность 408 (как у стока на внешнем экране, 320dp).
- patches/nfc: NXP. patches/camera: HEX-патчи и библиотеки F916B.
- installer: assertions только SM-F916B не ниже KXH1, recovery.fstab = стоковый.
- tools/vbmeta-F916BXXS7KXH1-flags3.img: стоковый vbmeta с отключённой проверкой.
- HFR: 60 Гц, режим 0 (как a71 в UN1CA): 120 Гц у стока - только внутренний экран.
- Ядро план B (kernel-src/0001): сверено с CAF-композером sm8250 (LineageOS lineage-20.0-caf-sm8250):
  основной дисплей HWC = "display type=primary" из ядра (теперь внешний); отключённый внутренний
  HWDeviceDRM::Init отбрасывает (kErrorDeviceRemoved), HandleBuiltInDisplays только пишет warning;
  яркость идёт по номеру DSI (panel%d-backlight), а не по роли - не меняется. Samsung-композер
  (vendor F916B) закрыт - проверять по logcat SDM/HWComposer на телефоне.
- Релиз: BOOT_dual_f2q / BOOT_cover_f2q - смена режима экрана через Odin без пересборки.

Проверить на телефоне (по логам первой загрузки):
- WLAN/BT/eSE флаги оставлены от r8q.
- Камера: MASS_APP_FLAVOR=false (камера S22 + патчи legacy/camera UN1CA). Если сборка упала
  на патче SamsungCamera.apk или камера падает — запустить workflow с camera_mass=true (как r8q).
- overlay: physical_power_button_center_screen_location_y=918px — оценка, не из стока.
- Экраны: строка «раскладка экранов» в pc_check_phone.sh (адрес основного экрана из displayconfig
  среди экранов Android, режим ядра, DSI-1/DSI-2). Если ВНИМАНИЕ или чёрный экран - BOOT_cover_f2q.
  В плане A: нет ли в dmesg ошибок/ESD внутренней панели (DSI-1), не просыпается ли она при открытии.
- RIL: используется стоковый RIL F916B. Библиотеки r8q (android16/disabled-r8q-patches/ril) —
  только эксперимент, если связь не заработает: смотреть `adb logcat -b radio`.
- Две SIM: singlesim отключён (android16/disabled-r8q-patches/singlesim),
  проверить ro.multisim.* в отчёте pc_check_phone.sh (подробности «связь»).
