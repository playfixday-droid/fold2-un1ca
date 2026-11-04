# Телефон - витринный образец (LDU): у него код продукта SM-F916BZN8..., 11-й символ '8'.
# services.jar (ScanPackageUtils): PMRune.PM_LDU && PackageBlockListPolicy.isBlocked(pkg) -> "is forbidden to install";
# PM_LDU = PackageSamsungUtils.isLduSkuBinary(): ril.product_code.charAt(10) == '8' || '9' (из /efs/imei/prodcode.dat).
# Список - /system/etc/ldu_blocklist.xml (331 приложение: AIDA64, AnTuTu, CPU-Z ...). Пустой список = запрета нет.
F="$WORK_DIR/system/system/etc/ldu_blocklist.xml"
if [ -f "$F" ]; then
    LOG "- Emptying /system/etc/ldu_blocklist.xml"
    EVAL "cp -a \"$MODPATH/files/ldu_blocklist.xml\" \"$F\""
    SET_METADATA "system" "system/etc/ldu_blocklist.xml" 0 0 644 "u:object_r:system_file:s0"
else
    LOGW "Нет /system/etc/ldu_blocklist.xml, пропуск"
fi
unset F
