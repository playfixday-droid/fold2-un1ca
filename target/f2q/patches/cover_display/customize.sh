# Внутренний экран мёртв: внешний (address ...154) основной во всех состояниях.
# Механизм AOSP DeviceStateToLayoutMap, Samsung читает его из /vendor/etc/displayconfig/.
# Файлы = стоковые F916BXXS7KXH1 с переставленными адресами экранов.
for f in "display_layout_configuration.xml" "sec/display_layout_configuration.xml"; do
    if [ ! -f "$WORK_DIR/vendor/etc/displayconfig/$f" ]; then
        LOGW "Нет /vendor/etc/displayconfig/$f в vendor F916B, пропуск"
        continue
    fi
    LOG "- Replacing /vendor/etc/displayconfig/$f"
    EVAL "cp -a \"$MODPATH/files/$f\" \"$WORK_DIR/vendor/etc/displayconfig/$f\""
    SET_METADATA "vendor" "etc/displayconfig/$f" 0 0 644 "u:object_r:vendor_configs_file:s0"
done

# Плотность: в vendor F916B ro.sf.lcd_density=480 (стоковый Samsung-фреймворк Fold пересчитывает её
# для каждого экрана, фреймворк S22 — нет). 480 на внешнем 816 px = 272 dp, меньше минимума 320 dp.
# 408 — стоковая плотность внешнего экрана Fold2 (816 px = 320 dp).
if [[ "$(GET_PROP "vendor" "ro.sf.lcd_density")" == "480" ]]; then
    SET_PROP "vendor" "ro.sf.lcd_density" "408"
else
    LOGW "ro.sf.lcd_density в vendor не 480, плотность не меняю"
fi
