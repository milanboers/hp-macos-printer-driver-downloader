#!/bin/bash
#
# Removes everything ./install.sh added for the HP LaserJet Pro M102a (M101-M106) driver.
#
# Usage: sudo ./uninstall.sh [--queue NAME] [--keep-queue]
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="/Library/Printers/hp/.hp-m101-m106.manifest"
QUEUE="HP_LaserJet_M101_M106"

KEEP_QUEUE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--queue)      QUEUE="${2:-}"; shift ;;
		--keep-queue) KEEP_QUEUE=1 ;;
		-h|--help)    sed -n '2,6p' "$0"; exit 0 ;;
		*)            echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

if [ "$(id -u)" -ne 0 ]; then
	echo "Must run as root:" >&2
	echo "" >&2
	echo "    sudo $0 $*" >&2
	exit 1
fi

if [ "$KEEP_QUEUE" -eq 0 ]; then
	echo "==> Removing print queue '$QUEUE'"
	lpadmin -x "$QUEUE" 2>/dev/null || true
fi

if [ -f "$MANIFEST" ]; then
	echo "==> Removing installed files"
	# deepest paths first, then prune the directories we emptied
	sort -r "$MANIFEST" | while IFS= read -r rel; do
		if [ -n "$rel" ]; then rm -f "/$rel"; fi
	done
	sort -r "$MANIFEST" | while IFS= read -r rel; do
		if [ -n "$rel" ]; then rmdir "/$(dirname "$rel")" 2>/dev/null || true; fi
	done
	rm -f "$MANIFEST"
	rmdir /Library/Printers/hp/cups/filters 2>/dev/null || true
	rmdir /Library/Printers/hp/cups 2>/dev/null || true
	rmdir /Library/Printers/hp 2>/dev/null || true
else
	echo "==> No manifest found; removing the paths install.sh is known to use"
	rm -rf "/Library/Printers/hp/cups/filters/raster2pclm.filter" \
	       "/Library/Printers/hp/cups/filters/commandtohp.filter" \
	       "/Library/Printers/hp/cups/tools/epcl2ppd.tool" \
	       "/Library/Printers/hp/filter/hpPreProcessing.filter" \
	       "/Library/Printers/hp/Frameworks/HPDM.framework" \
	       "/Library/Printers/hp/Frameworks/HPDriverCore.framework" \
	       "/Library/Printers/PPDs/Contents/Resources/HP LaserJet M101-M106.ppd.gz"
	echo "    (if you installed --with-pde/--with-utility, remove /Library/Printers/hp/PDEs and"
	echo "     /Library/Printers/hp/Utilities by hand)"
fi

echo "==> Restarting CUPS"
killall cupsd 2>/dev/null || true

echo "Done."
