#!/system/bin/sh
# fold2: копия разделов с IMEI, калибровками радио и ключами устройства - ТОЛЬКО ЧТЕНИЕ, ничего не пишет в разделы.
# EFS у Fold2 две: у SM8250 (modemst1/2, fsg, fsc) и у модема SDX55 (mdm1m9kefs1/2/3/c), плюс persist, param и т.д.
# С ПК:  adb push backup_efs.sh /data/local/tmp/ && adb shell su -c "sh /data/local/tmp/backup_efs.sh"
#        adb exec-out su -c "cat /data/local/fold2-efs/fold2-efs-<время>.tar.gz" > fold2-efs-<время>.tar.gz
#        (затем: adb shell su -c "rm /data/local/fold2-efs/fold2-efs-*")
# Архив - в /data/local/fold2-efs (0700, только root), не в /data/local/tmp: тот читают adb и приложения с Shizuku (uid shell).
# В архиве IMEI и ключи этого телефона: храни как пароль и никуда не выкладывай. Записывать образы обратно вслепую
# нельзя - не тот образ в этих разделах означает потерю IMEI и сети.
say() { echo "[fold2-efs] $*"; }
die() { echo "[fold2-efs] ОШИБКА: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "нужен root: su -c \"sh $0\""
BN=/dev/block/bootdevice/by-name; [ -d "$BN" ] || BN=/dev/block/by-name
[ -d "$BN" ] || die "нет /dev/block/by-name"
NAMES="efs sec_efs modemst1 modemst2 fsg fsc mdm1m9kefs1 mdm1m9kefs2 mdm1m9kefs3 mdm1m9kefsc persist steady param devinfo keystore persistent spunvm"
W=/data/local/fold2-efs
T=fold2-efs-$(date +%Y%m%d-%H%M%S); O=$W/$T
umask 077
mkdir -p "$W" && chown 0:0 "$W" 2>/dev/null; chmod 700 "$W" || die "не создать $W"
mkdir -p "$O" || die "не создать $O"
N=0; BAD=0
for P in $NAMES; do
  L=""
  for X in "$BN"/*; do # имена в by-name бывают и заглавными (как в PIT)
    [ "$(printf '%s' "${X##*/}" | tr '[:upper:]' '[:lower:]')" = "$P" ] && { L=$X; break; }
  done
  [ -n "$L" ] || { say "  нет раздела $P - пропускаю"; continue; }
  if ! dd if="$L" of="$O/$P.img" bs=1048576 2>/dev/null; then say "  ОШИБКА чтения $P"; BAD=1; continue; fi
  F=$(wc -c <"$O/$P.img"); F=$((F)); S=$(blockdev --getsize64 "$L" 2>/dev/null)
  if [ -n "$S" ] && [ "$S" != "$F" ]; then say "  ОШИБКА: $P - прочитано $F из $S байт"; BAD=1; fi
  N=$((N + 1)); say "  $P: $F байт"
done
[ "$N" -gt 0 ] || { rm -rf "$O"; die "ни одного раздела не прочитано"; }
{ echo "собрано: $(date)"; for P in ro.product.model ro.boot.bootloader ro.build.display.id; do echo "$P=$(getprop "$P" 2>/dev/null)"; done
  echo "by-name: $BN"; } >"$O/info.txt"
(cd "$O" && sha256sum ./*.img >SHA256SUMS) || die "sha256sum не сработал"
tar -czf "$O.tar.gz" -C "$W" "$T" || die "tar не сработал (образы остались в $O)"
rm -rf "$O"
chmod 600 "$O.tar.gz"
say "готово: $O.tar.gz ($N разделов$([ "$BAD" = 1 ] && echo ', БЫЛИ ОШИБКИ - см. выше'))"
say "забери на ПК: adb exec-out su -c \"cat $O.tar.gz\" > ${O##*/}.tar.gz   и удали с телефона: adb shell su -c \"rm $O.tar.gz\""
[ "$BAD" = 0 ]
