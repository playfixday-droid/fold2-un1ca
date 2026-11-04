# Разгон GPU: частоты 700/750/800 МГц добавляет kernel-src/0003-f2q-gpu-oc.patch (DT ядра).
# Здесь: предел 670 МГц при загрузке (vendor init) и fold2-gpu для смены предела на ходу.
if [ ! -d "$WORK_DIR/vendor/etc/init" ]; then
    ABORT "Нет vendor/etc/init в WORK_DIR"
fi
LOG "- Adding /vendor/etc/init/fold2-gpu.rc"
EVAL "cp -a \"$MODPATH/files/fold2-gpu.rc\" \"$WORK_DIR/vendor/etc/init/fold2-gpu.rc\""
SET_METADATA "vendor" "etc/init/fold2-gpu.rc" 0 0 644 "u:object_r:vendor_configs_file:s0"

LOG "- Adding /system/bin/fold2-gpu"
EVAL "cp -a \"$MODPATH/files/fold2-gpu\" \"$WORK_DIR/system/system/bin/fold2-gpu\""
EVAL "chmod 755 \"$WORK_DIR/system/system/bin/fold2-gpu\""
SET_METADATA "system" "system/bin/fold2-gpu" 0 2000 755 "u:object_r:system_file:s0"
