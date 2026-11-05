LOG "- Patching /vendor/etc/fstab.qcom"
EVAL "sed -i \"/[[:space:]]\/data[[:space:]]/ s|fileencryption=ice|formattable,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized,fscompress,keydirectory=/metadata/vold/metadata_encryption,sysfs_path=/sys/devices/platform/soc/1d84000.ufshc|g\" \"$WORK_DIR/vendor/etc/fstab.qcom\""
EVAL "sed -i \"/Samsung ODE/,+2d\" \"$WORK_DIR/vendor/etc/fstab.qcom\""
# formattable (как /data в LineageOS sm8250-common): стёртую или недошифрованную /data fs_mgr отдаёт vold на
# форматирование (encryptFstab shouldFormat=true) вместо отказа монтирования и перезагрузки в recovery.
