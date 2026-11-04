# f2q: UN1CA kernel built from source with vendor/samsung/f2q.config + f2q-hw.config + docker.config
# and kernel-src/*.patch. The GitHub workflow (build-f2q.yml) puts the images into
# target/f2q/patches/kernel/prebuilt/ (boot-f2q-dual.img or boot-f2q-cover.img -> boot.img).
# For a local build: bash target/f2q/kernel-src/make_boot.sh <kernel_tree> <out> and copy them there.
PREBUILT="$SRC_DIR/target/$TARGET_CODENAME/patches/kernel/prebuilt"
for f in boot.img dtbo.img; do
    if [ ! -f "$PREBUILT/$f" ]; then
        ABORT "File not found: target/$TARGET_CODENAME/patches/kernel/prebuilt/$f (build the f2q kernel first)"
    fi
done

LOG "- Using prebuilt f2q kernel"
EVAL "mkdir -p \"$WORK_DIR/kernel\""
EVAL "cp -a \"$PREBUILT/boot.img\" \"$WORK_DIR/kernel/boot.img\""
EVAL "cp -a \"$PREBUILT/dtbo.img\" \"$WORK_DIR/kernel/dtbo.img\""

unset PREBUILT
