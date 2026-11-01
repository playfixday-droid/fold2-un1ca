# f2q: один чип NXP (SN100U), конфиг в стоке называется libnfc-nci.conf.
# S22-система ищет libnfc-nci-<sku>.conf -> кладём его как sn110t (семейство NXP).
LOG_STEP_IN "- Setting up libnfc-nci configuration (NXP SN100U)"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/etc/libnfc-nci.conf" 0 0 644 "u:object_r:system_file:s0"
EVAL "cp -a \"$WORK_DIR/system/system/etc/libnfc-nci.conf\" \"$WORK_DIR/system/system/etc/libnfc-nci-sn110t.conf\""
SET_METADATA "system" "system/etc/libnfc-nci-sn110t.conf" 0 0 644 "u:object_r:system_file:s0"
LOG_STEP_OUT

LOG "- Patching /vendor/etc/init/init.nfc.samsung.rc"
EVAL "echo \"\" >> \"$WORK_DIR/vendor/etc/init/init.nfc.samsung.rc\""
EVAL "echo \"on property:ro.boot.product.hardware.sku=\\\"\\\"\" >> \"$WORK_DIR/vendor/etc/init/init.nfc.samsung.rc\""
EVAL "echo \"    setprop ro.boot.product.hardware.sku \\\"sn110t\\\"\" >> \"$WORK_DIR/vendor/etc/init/init.nfc.samsung.rc\""
EVAL "echo \"\" >> \"$WORK_DIR/vendor/etc/init/init.nfc.samsung.rc\""
EVAL "echo \"on property:ro.vendor.nfc.feature.chipname=\\\"\\\"\" >> \"$WORK_DIR/vendor/etc/init/init.nfc.samsung.rc\""
EVAL "echo \"    setprop ro.vendor.nfc.feature.chipname \\\"NXP_SN100U\\\"\" >> \"$WORK_DIR/vendor/etc/init/init.nfc.samsung.rc\""
