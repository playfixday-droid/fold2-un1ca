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
- Ядро (f2q-4): kernel-src/f2q-hw.config - драйвер вибромотора CS40L25 (cs40l2x + timed_output, как у стока и
  c2q.config), в f2q.config UN1CA его не было: в f2q-3 вибрации нет. Плюс CFS_BANDWIDTH (docker --cpus).
  CI проверяет, что все =y из f2q-hw.config и docker.config попали в .config и что cs40l2x.o собран.
- Ядро (f2q-5): docker.config + SysV IPC, binfmt_misc, NAT IPv6, nftables (для Debian, как в Kali NetHunter).
  Прошивка: только AP + CSC, BL и CP не шьются (на телефоне уже KXH1).
- Совместимость f2q-3 со стоком KXH1 (2026-11-04): vendor/odm стоковые (+стандартные замены UN1CA), VINTF без
  недостающих обязательных HAL, DTB/dtbo (все 12 ревизий платы, вкл. Rev0.7), cmdline, fstab, размеры super - сходятся.
  Из ядра стока сознательно нет: DEFEX/FIVE/PROCA/UH/RKP/KDP, coresight/отладка, SDCARD_FS.

Проверить на телефоне (по логам первой загрузки):
- Вибрация (f2q-4): check_phone.sh, пункт «вибромотор»; dmesg | grep -i cs40l.
- WLAN/BT/eSE флаги оставлены от r8q.
- Камера: MASS_APP_FLAVOR=false (камера S22 + патчи legacy/camera UN1CA). Если сборка упала
  на патче SamsungCamera.apk или камера падает — запустить workflow с camera_mass=true (как r8q).
- overlay: physical_power_button_center_screen_location_y=918px — оценка, не из стока.
- 120 Гц на внешнем экране: у стока внешний экран 60 Гц, HFR относится к внутреннему.
- RIL: используется стоковый RIL F916B. Библиотеки r8q (android16/disabled-r8q-patches/ril) —
  только эксперимент, если связь не заработает: смотреть `adb logcat -b radio`.
- Две SIM: singlesim отключён (android16/disabled-r8q-patches/singlesim),
  проверить ro.multisim.* в collect_info.
