#!/bin/bash
# Упаковка boot.img для f2q из собранного ядра UN1CA (как build.sh UN1CA, header v2).
# Использование: make_boot.sh <kernel_tree> <out_dir> [BOARD]
# BOARD взять из стокового boot.img F916B: python3 unpack_bootimg.py --boot_img boot.img
set -e
K=${1:?kernel tree}; O=${2:?out dir}; BOARD=${3:-SRPTC13A007}  # board стокового boot.img F916BXXS7KXH1
MKB=${MKBOOTIMG:-/data/tools/mkbootimg/mkbootimg.py}
mkdir -p "$O"
cat "$K"/out/arch/arm64/boot/dts/vendor/qcom/*.dtb > "$O/dtb"
CMD="console=null androidboot.hardware=qcom androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 printk.devkmsg=on firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7"
mk() { python3 "$MKB" --header_version 2 --kernel "$K/out/arch/arm64/boot/Image" \
  --ramdisk "$K/boot/ramdisk" --dtb "$O/dtb" --cmdline "$1" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x02000000 \
  --second_offset 0x00000000 --dtb_offset 0x01f00000 --tags_offset 0x01e00000 \
  --board "$BOARD" --pagesize 4096 --os_version 16.0.0 --os_patch_level "$(date +%Y-%m)" \
  --output "$2"; }
mk "$CMD" "$O/boot-f2q-dual.img"                              # оба экрана, как сток
mk "$CMD msm_drm.f2q_cover_only=1" "$O/boot-f2q-cover.img"     # только внешний экран
cp "$K/out/arch/arm64/boot/dtbo.img" "$O/dtbo.img"
rm -f "$O/dtb"
ls -la "$O"
