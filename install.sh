#!/bin/bash
#
# Installs what ./fetch-driver.sh unpacked into driver/root.
#
# Copies the tree into /Library/Printers, fixes ownership and permissions, restarts CUPS, and
# creates a print queue for the attached printer. The files it added are recorded in
# /Library/Printers/hp/.hp-m101-m106.manifest so uninstall.sh can remove exactly those.
#
# Verified for the LaserJet bundle (B). For the inkjet bundles HP's own installer is the better
# route: their filters and print-dialog extensions are laid out differently.
#
# Usage: sudo ./install.sh [--ppd FILE.ppd.gz] [--queue NAME] [--no-queue] [--no-default] [--dry-run]
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/driver/root"
PPD_DIR="$ROOT/Library/Printers/PPDs/Contents/Resources"
MANIFEST="/Library/Printers/hp/.hp-m101-m106.manifest"

PPD=""
QUEUE=""
MAKE_QUEUE=1
MAKE_DEFAULT=1
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--ppd)        PPD="${2:-}"; shift ;;
		--queue)      QUEUE="${2:-}"; shift ;;
		--no-queue)   MAKE_QUEUE=0 ;;
		--no-default) MAKE_DEFAULT=0 ;;
		--dry-run)    DRY_RUN=1 ;;
		-h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
		*)            echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

[ -d "$ROOT/Library/Printers" ] || {
	echo "driver/root is empty - run ./fetch-driver.sh first (see --list)" >&2
	exit 1
}

# ---------------------------------------------------------------- pick a PPD and a device

# the attached printer's family name, from the CUPS usb backend's device id
device_line=$(lpinfo -l -v 2>/dev/null | awk '/device-id/ && /MDL:/ && !l { l = $0 } END { print l }')
device_model=$(printf '%s' "$device_line" | sed -n 's/.*MDL:\([^;]*\).*/\1/p')

ppds=$(find "$PPD_DIR" -name '*.ppd.gz' 2>/dev/null | sort)
[ -n "$ppds" ] || { echo "no PPDs in $PPD_DIR - wrong bundle?" >&2; exit 1; }

if [ -z "$PPD" ] && [ -n "$device_model" ]; then
	PPD=$(printf '%s\n' "$ppds" | awk -v m="$device_model" \
		'BEGIN { m = tolower(m) } { if (!f && index(tolower($0), m)) f = $0 } END { print f }')
fi
if [ -z "$PPD" ]; then
	# no printer attached: prefer the one this repo was verified with, else take the only one
	PPD=$(printf '%s\n' "$ppds" | awk '/HP LaserJet M101-M106\.ppd\.gz$/ && !f { f = $0 } END { print f }')
fi
if [ -z "$PPD" ]; then
	count=$(printf '%s\n' "$ppds" | wc -l | tr -d ' ')
	if [ "$count" = 1 ]; then
		PPD="$ppds"
	else
		echo "no printer detected and this bundle has $count PPDs; pick one with --ppd:" >&2
		printf '  %s\n' $ppds >&2
		exit 1
	fi
fi

# queue name from the PPD, e.g. "HP LaserJet M101-M106" -> HP_LaserJet_M101_M106
if [ -z "$QUEUE" ]; then
	QUEUE=$(basename "$PPD" .ppd.gz | tr -cs 'A-Za-z0-9' '_' | sed 's/_$//')
fi

if [ "$MAKE_QUEUE" = 1 ]; then
	URI=$(lpinfo -v 2>/dev/null | awk '$1 == "direct" && $2 ~ /^usb:\/\// && !u { u = $2 } END { print u }')
else
	URI=""
fi

# what CUPS calls this PPD in `lpinfo -m`, i.e. its path relative to /Library/Printers/PPDs
MODEL="Library/Printers/PPDs/Contents/Resources/$(basename "$PPD")"
INSTALLED_PPD="/Library/Printers/PPDs/Contents/Resources/$(basename "$PPD")"

if [ "$DRY_RUN" = 1 ]; then
	echo "would install : $(find "$ROOT" \( -type f -o -type l \) | wc -l | tr -d ' ') files from $ROOT into /Library/Printers"
	echo "PPD           : $(basename "$PPD")"
	[ -n "$device_model" ] && echo "detected      : $device_model"
	[ "$MAKE_QUEUE" = 1 ] && echo "queue         : $QUEUE on ${URI:-<no usb device found>}"
	echo "uninstall     : sudo ./uninstall.sh --queue $QUEUE"
	exit 0
fi

# ---------------------------------------------------------------- install

if [ "$(id -u)" -ne 0 ]; then
	echo "This installs into /Library/Printers and must run as root:" >&2
	echo "" >&2
	echo "    sudo $0 $*" >&2
	exit 1
fi

mkdir -p /Library/Printers/hp
( cd "$ROOT" && find . \( -type f -o -type l \) -print ) | sed 's|^\./||' > "$MANIFEST"
echo "==> Installing $(wc -l < "$MANIFEST" | tr -d ' ') files from driver/root into /Library/Printers"
ditto "$ROOT" /

echo "==> Fixing ownership and permissions"
chown -R root:wheel /Library/Printers/hp
chmod -R go-w /Library/Printers/hp
xattr -r -d com.apple.quarantine /Library/Printers/hp 2>/dev/null || true
# PPDs: only touch the ones we installed, leave any other vendor's PPDs alone
grep '^Library/Printers/PPDs/' "$MANIFEST" | while IFS= read -r rel; do
	chown root:wheel "/$rel" 2>/dev/null || true
	chmod 644 "/$rel" 2>/dev/null || true
done || true

echo "==> Checking HP code signatures"
if codesign -v /Library/Printers/hp/cups/filters/raster2pclm.filter 2>/dev/null ||
   codesign -v /Library/Printers/hp/Frameworks/HPDM.framework 2>/dev/null; then
	echo "    signatures intact"
else
	echo "    note: no HP signature to verify for this bundle" >&2
fi

# ---------------------------------------------------------------- print queue

if [ "$MAKE_QUEUE" = 1 ]; then
	echo "==> Restarting CUPS"
	killall cupsd 2>/dev/null || true
	for _ in $(seq 1 20); do
		lpstat -r >/dev/null 2>&1 && break
		sleep 0.5
	done

	if lpstat -p "$QUEUE" >/dev/null 2>&1; then
		echo "==> Queue '$QUEUE' already exists, leaving it alone"
	elif [ -z "$URI" ]; then
		echo "==> No USB printer found right now."
		echo "    Connect it, then add it in System Settings > Printers & Scanners;"
		echo "    the driver is listed as \"$(basename "$PPD" .ppd.gz)\"."
	elif lpadmin -p "$QUEUE" -E -v "$URI" -m "$MODEL" -D "$(basename "$PPD" .ppd.gz)" -L "USB" 2>/dev/null; then
		echo "==> Created queue '$QUEUE' on $URI"
	elif lpadmin -p "$QUEUE" -E -v "$URI" -m "$INSTALLED_PPD" -D "$(basename "$PPD" .ppd.gz)" -L "USB" 2>/dev/null; then
		echo "==> Created queue '$QUEUE' on $URI"
	else
		# last resort: create a stock queue, then drop the PPD in place for cupsd to re-read
		echo "==> lpadmin would not take the PPD; creating the queue and replacing its PPD"
		lpadmin -p "$QUEUE" -E -v "$URI" -m "drv:///sample.drv/laserjet.ppd" -D "$(basename "$PPD" .ppd.gz)" -L "USB"
		gzip -dc "$PPD" > "/etc/cups/ppd/$QUEUE.ppd"
		chown root:_lp "/etc/cups/ppd/$QUEUE.ppd"
		chmod 600 "/etc/cups/ppd/$QUEUE.ppd"
		killall cupsd 2>/dev/null || true
		sleep 1
	fi
	lpstat -p "$QUEUE" 2>/dev/null || true

	if [ "$MAKE_DEFAULT" = 1 ] && lpstat -p "$QUEUE" >/dev/null 2>&1; then
		lpadmin -d "$QUEUE" 2>/dev/null && echo "==> '$QUEUE' is now the default printer"
	fi
fi

echo ""
echo "Done."
echo "    test:      echo hello | lp -d $QUEUE"
echo "    uninstall: sudo $HERE/uninstall.sh --queue $QUEUE"
