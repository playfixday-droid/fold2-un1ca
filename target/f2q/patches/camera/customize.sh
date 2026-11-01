# Add Polarr libs
ADD_TO_WORK_DIR "a73xqxx" "system" "system/etc/public.libraries-polarr.txt" 0 0 644 "u:object_r:system_file:s0"
ADD_TO_WORK_DIR "a73xqxx" "system" "system/lib64/libBestComposition.polarr.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "a73xqxx" "system" "system/lib64/libFeature.polarr.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "a73xqxx" "system" "system/lib64/libPolarrSnap.polarr.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "a73xqxx" "system" "system/lib64/libTracking.polarr.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "a73xqxx" "system" "system/lib64/libYuv.polarr.so" 0 0 644 "u:object_r:system_lib_file:s0"

# Add camera libs
ADD_TO_WORK_DIR "r9qxxx" "system" "system/lib64/libSceneDetector_v1.camera.samsung.so" 0 0 644 "u:object_r:system_lib_file:s0"
EVAL "echo \"libSceneDetector_v1.camera.samsung.so\" >> \"$WORK_DIR/system/system/etc/public.libraries-camera.samsung.txt\""
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/libSwIsp_core.camera.samsung.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/libhigh_dynamic_range.arcsoft.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/libhigh_res.arcsoft.so" 0 0 644 "u:object_r:system_lib_file:s0"
EVAL "echo \"libhigh_res.arcsoft.so\" >> \"$WORK_DIR/system/system/etc/public.libraries-arcsoft.txt\""
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/libhumantracking.arcsoft.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/libhumantracking_util.camera.samsung.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/liblow_light_hdr.arcsoft.so" 0 0 644 "u:object_r:system_lib_file:s0"
HEX_PATCH "$WORK_DIR/system/system/lib64/libsecimaging_pdk.camera.samsung.so" \
    "000000006400000046000000000000000b00000001000000070000000000000000000000" \
    "000000006400000046000000000000000b00000001000000050000000000000000000000"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/libveengine.arcsoft.so" 0 0 644 "u:object_r:system_lib_file:s0"

LOG "- Patching /vendor/ueventd.rc"
EVAL "cat \"$MODPATH/ueventd.rc.diff\" >> \"$WORK_DIR/vendor/ueventd.rc\""

# Force disable ScenarioManager::IsSupported3rdPartyYuvCapture()
# f2q: у F916B библиотека называется unihal_main.so (у r8q unihal_main@2.1.so),
# байты свои. Проверено дизассемблером на F916BXXS7KXH1: условный переход в начале
# функции заменён на NOP -> функция всегда возвращает false (как патч r8q).
# lib:   [cbz r0, #0xb0ac0] -> [nop]
HEX_PATCH "$WORK_DIR/vendor/lib/unihal_main.so" "90f8b80018b10024" "90f8b80000bf0024"
# lib64: [cbz w8, #0xe8100] -> [nop]
HEX_PATCH "$WORK_DIR/vendor/lib64/unihal_main.so" "08e04439e8000034f3031f2a" "08e044391f2003d5f3031f2a"

# Force disable Snaplite in Shot suggestions
# Before: [blt #0x1f890]
# After: [b #0x1f890]
HEX_PATCH "$WORK_DIR/vendor/lib/libshotsuggestion_engines.so" "0ddb" "0de0"

# Before: [b.lt 0x40dedc]
# After: [b 0x40dedc]
HEX_PATCH "$WORK_DIR/vendor/lib64/libshotsuggestion_engines.so" "eb010054" "0f000014"
