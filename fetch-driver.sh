#!/bin/bash
#
# HP's newest macOS printer drivers - find and fetch them.
#
# HP no longer delivers a macOS driver for these printers: HP Easy Start asks HP's software catalogue,
# which answers "NOT SUPPORTED" for anything current, and Apple ships no HP drivers any more. The
# newest release they published (printer-essentials 5.20.0.1, the macOS 26 build dated 2025-11-06) is
# still sitting on ftp.hp.com, split into seven bundles covering ~190 printer families. Nothing on
# hp.com links to it.
#
# This script knows where those bundles are and which models each one covers, and pulls just the
# driver sub-packages out of the one you need: about 25 MB of HTTP range requests instead of the
# whole 300-500 MB archive, with every byte checked against the sha1 in HP's own table of contents.
#
# Usage:
#   ./fetch-driver.sh                           do it for the attached printer: find its bundle,
#                                               then install: Enter or y takes HP's own installer,
#                                               l the light install that also adds a queue
#   ./fetch-driver.sh --list                    what HP still serves, and what each bundle covers
#   ./fetch-driver.sh --find "LaserJet M102"    search model names, PPD names and icon names
#   ./fetch-driver.sh --mine                    read the attached printer's ID and find its bundle
#   ./fetch-driver.sh --bundle B                fetch that bundle's driver into driver/root, then
#                                               offer to install it and add a print queue
#   ./fetch-driver.sh --product "M102a"         same, choosing the bundle by model name
#   ./fetch-driver.sh --ppd "HP LaserJet M101-M106.ppd.gz"
#   ./fetch-driver.sh --check                   ask HP's catalogue for the newest version it offers
#                                               for this printer, and compare with the catalog
#
# Options:
#   --dest DIR      where to unpack (default: driver/root)
#   --with-pde      also fetch the print-dialog extension (watermark/booklet/duplex panes)
#   --with-utility  also fetch HP Utility.app (~150 MB, only needed for the Utility button)
#   --install       install without asking (needs sudo; also works on its own, to install what was
#                   already fetched into driver/root)
#   --no-install    fetch only, never offer to install
#   --fresh         empty the destination first (default for driver/root, which is replaced)
#   --hp-installer  download the whole bundle (313-364 MB) and open HP's own installer instead
#   --dry-run       report what would be fetched and how much, fetch nothing
#   --url           print the whole-bundle URL instead of fetching (for HP's own installer)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$HERE/catalog/bundles.tsv"
FETCHER="$HERE/tools/hp-fetch.py"
DEST="$HERE/driver/root"

BUNDLE=""
FIND=""
INSTALL=ask      # ask | yes | no
FRESH=0
HP_INSTALLER=0   # --hp-installer: hand the whole bundle to HP's own installer instead
ACTION=find      # --find only searches; --product/--ppd/--bundle also fetch
MINE=0
CHECK=0
MODEL=""
LIST=0
SHOW_URL=0
DRY_RUN=0
WITH_PDE=0
WITH_UTILITY=0
BUNDLES=""

die() { echo "$*" >&2; exit 1; }

usage() { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; }

require_python() {
	if ! command -v python3 >/dev/null 2>&1; then
		die "python3 is needed for this step. On macOS: xcode-select --install"
	fi
	if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)' 2>/dev/null; then
		echo "python3 on PATH does not run, or is older than 3.7." >&2
		echo "A fresh macOS has /usr/bin/python3 as a stub until the Command Line Tools are installed:" >&2
		echo "" >&2
		echo "    xcode-select --install" >&2
		exit 1
	fi
}

rows() { grep -v '^#' "$CATALOG"; }

# first value of a column for a bundle; awk reads everything so nothing gets SIGPIPE'd
field() {
	rows | awk -F'\t' -v b="$1" -v c="$2" '$1 == b && !v { v = $c } END { print v }'
}

count() {
	rows | awk -F'\t' -v b="$1" -v k="$2" '$1 == b && $7 == k { n++ } END { print n + 0 }'
}

list_bundles() {
	printf '%-7s %-9s %7s %7s %6s %7s  %s\n' \
		bundle version size print_ppds icons models "example models"
	for b in $(rows | awk -F'\t' '{ if (!seen[$1]++) print $1 }'); do
		size=$(field "$b" 4)
		example=$(rows | awk -F'\t' -v b="$b" '$1 == b && $7 == "product" {
			if (n++ < 2) printf "%s%s", (n > 1 ? ", " : ""), $8 }')
		printf '%-7s %-9s %5.0f MB %7s %6s %7s  %s\n' \
			"$b" "$(field "$b" 3 | tr '_' '.')" \
			"$(awk -v s="$size" 'BEGIN { print s / 1e6 }')" \
			"$(count "$b" print)" "$(count "$b" icon)" "$(count "$b" product)" "$example"
	done
}

# print matching catalog rows; leaves the matching bundle letters in BUNDLES
search() {
	local pattern="$1"
	BUNDLES=$(rows | awk -F'\t' -v p="$pattern" '$7 != "fax" && tolower($8) ~ tolower(p) { print $1 }' | sort -u)
	rows | awk -F'\t' -v p="$pattern" '
		$7 != "fax" && tolower($8) ~ tolower(p) {
			key = $1 "\t" $7
			if (!(key in seen)) { order[++n] = key; seen[key] = 1 }
			if (count[key]++ < 3) names[key] = names[key] (count[key] > 1 ? ", " : "") $8
			total++
		}
		END {
			for (i = 1; i <= n; i++) {
				split(order[i], f, "\t")
				extra = count[order[i]] > 3 ? sprintf(" (+%d more)", count[order[i]] - 3) : ""
				printf "  bundle %-2s %-8s %s%s\n", f[1], f[2], names[order[i]], extra
			}
			if (!total) exit 1
		}'
}

# the files are on disk now; hand them to install.sh, which is the part that needs root
install_now() {
	if [ "$DRY_RUN" = 1 ]; then
		echo "    would then run: sudo $HERE/install.sh"
		return 0
	fi
	[ -x "$HERE/install.sh" ] || die "install.sh is missing next to this script"
	echo "==> sudo $HERE/install.sh"
	exec sudo "$HERE/install.sh"
}

# the other end of the same job: let HP's own installer do everything
open_hp_installer() {
	local url name size out
	url=$(field "$BUNDLE" 5)
	size=$(field "$BUNDLE" 4)
	[ -n "$url" ] || die "unknown bundle '$BUNDLE' (see --list)"
	name=$(basename "$url")
	out="$HOME/Downloads/$name"

	if [ "$DRY_RUN" = 1 ]; then
		echo "    would download $(awk -v s="$size" 'BEGIN { printf "%.0f", s/1e6 }') MB"
		echo "    to $out, and open it with HP's installer"
		return 0
	fi

	if [ -f "$out" ]; then
		echo "==> Already downloaded: $out"
	else
		echo "==> Downloading HP's installer, $(awk -v s="$size" 'BEGIN { printf "%.0f", s/1e6 }') MB, to $out"
		mkdir -p "$HOME/Downloads"
		/usr/bin/curl -fL --progress-bar -o "$out.part" "$url" || die "download failed"
		/bin/mv "$out.part" "$out"
	fi
	echo "==> Opening it: HP's installer takes over from here"
	/usr/bin/open "$out"
	cat <<'EOS'

(HP's installer puts the full bundle in place - about 467 MB, including HP Utility and the fax
 driver - and installs no print queue, so the last step is yours: System Settings > Printers &
 Scanners > +, and the driver will be the one offered.
 For just the printing parts, with the queue created for you:  ./fetch-driver.sh --install)
EOS
}

# which of the two ends to use
act() {
	if [ "$HP_INSTALLER" = 1 ]; then
		open_hp_installer
	else
		fetch
	fi
}

fetch() {
	local pkgs url
	require_python
	pkgs=$(field "$BUNDLE" 6)
	url=$(field "$BUNDLE" 5)
	[ -n "$url" ] || die "unknown bundle '$BUNDLE' (see --list)"

	if [ "$WITH_PDE" = 1 ]; then
		pkgs="$pkgs,com.hp.print.ps.pde.pkg,com.hp.print.SmartPrint.A.pkg"
	fi
	if [ "$WITH_UTILITY" = 1 ]; then
		pkgs="$pkgs,com.hp.print.utility.pkg"
	fi

	echo "==> Bundle $BUNDLE: $(basename "$url")"
	echo "    $url"
	echo "    sub-packages: $pkgs"
	fresh=""
	if [ "$FRESH" = 1 ]; then
		fresh="--fresh"
	elif [ "$DEST" = "$HERE/driver/root" ] && [ -d "$DEST" ]; then
		fresh="--fresh"   # HP ships read-only files; replacing beats merging over them
	fi

	if [ "$DRY_RUN" = 1 ]; then
		python3 "$FETCHER" --url "$url" --pkgs "$pkgs" --dest "$DEST" $fresh --dry-run
		if [ "$INSTALL" != no ] && [ "$DEST" = "$HERE/driver/root" ]; then
			echo "    would then offer: sudo $HERE/install.sh"
		fi
		return 0
	fi

	echo "    unpacking into $DEST${fresh:+ (replacing what is there)}"
	python3 "$FETCHER" --url "$url" --pkgs "$pkgs" --dest "$DEST" $fresh
	echo ""

	# install.sh only ever installs driver/root, so a custom --dest cannot be offered
	if [ "$DEST" != "$HERE/driver/root" ]; then
		echo "Fetched into $DEST. install.sh installs driver/root, so install these by hand."
		return 0
	fi

	case "$INSTALL" in
		yes)
			install_now ;;
		no)
			echo "Fetched into $DEST. Install with:  sudo ./install.sh"
			echo "Or use HP's own installer (all 467 MB):  $url" ;;
		*)
			if [ -t 0 ] && [ -t 1 ]; then
				printf "Install them now? [Y] HP's own installer / [l] light install, queue included / [n] neither: "
				read -r reply || reply=""
				case "$reply" in
					[lL]*) install_now ;;
					[nN]*) echo "Left them in $DEST. Install later with:  sudo ./install.sh" ;;
					*) HP_INSTALLER=1; open_hp_installer ;;   # Enter or y: HP's installer
				esac
			else
				echo "Fetched into $DEST."
				echo "Install with HP's own installer:  ./fetch-driver.sh --bundle $BUNDLE --hp-installer"
				echo "Or install these files + a queue:  sudo ./install.sh"
			fi ;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
		--list)         LIST=1 ;;
		--find)         FIND="${2:-}"; shift ;;
		--product)      FIND="${2:-}"; ACTION=fetch; shift ;;
		--ppd)          FIND="${2:-}"; ACTION=fetch; shift ;;
		--mine)         MINE=1 ;;
		--check)        CHECK=1 ;;
		--model)        MODEL="${2:-}"; shift ;;
		--bundle)       BUNDLE="${2:-}"; shift ;;
		--dest)         DEST="${2:-}"; shift ;;
		--with-pde)     WITH_PDE=1 ;;
		--with-utility) WITH_UTILITY=1 ;;
		--install)      INSTALL=yes ;;
		--no-install)   INSTALL=no ;;
		--fresh)        FRESH=1 ;;
		--hp-installer) HP_INSTALLER=1 ;;
		--dry-run)      DRY_RUN=1 ;;
		--url)          SHOW_URL=1 ;;
		-h|--help)      usage; exit 0 ;;
		*)              die "unknown option: $1 (try --help)" ;;
	esac
	shift
done

[ -f "$CATALOG" ] || die "catalog/bundles.tsv is missing - this repo looks incomplete"

if [ "$LIST" = 1 ]; then
	list_bundles
	echo ""
	echo "Search a model with --find, or let --mine read it off the attached printer."
	exit 0
fi

if [ "$CHECK" = 1 ]; then
	if [ -z "$MODEL" ]; then
		# same sources --mine uses: the device id if readable, otherwise the device URI
		line=$(lpinfo -l -v 2>/dev/null | awk '/device-id/ && /MDL:/ && !l { l = $0 } END { print l }')
		if [ -n "$line" ]; then
			MODEL=$(printf '%s' "$line" | sed -n 's/.*MDL:\([^;]*\).*/\1/p')
			[ -n "$MODEL" ] || MODEL=$(printf '%s' "$line" | sed -n 's/.*DES:\([^;]*\).*/\1/p')
		fi
	fi
	if [ -z "$MODEL" ]; then
		MODEL=$({ lpinfo -v 2>/dev/null; lpstat -v 2>/dev/null; } |
			sed -n 's|.*usb://[^/]*/\([^?]*\).*|\1|p' | sed 's/%20/ /g' | sed -n '1p')
	fi
	[ -n "$MODEL" ] || die "nothing to check - pass --model \"HP LaserJet M101-M106\""

	require_python
	echo "==> Asking HP's catalogue about: $MODEL"
	python3 "$HERE/tools/hp-catalogue.py" --model "$MODEL" || exit 1

	newest=$(python3 "$HERE/tools/hp-catalogue.py" --model "$MODEL" --all 2>/dev/null |
		awk '/^  [0-9]/ && !seen { print $2; seen = 1 }')
	if [ -n "$newest" ]; then
		newest_name=${newest##*/}
		# compare file names, not URLs: the catalogue answers with ftp:// where we pin https://
		pinned=$(rows | awk -F'\t' -v n="$newest_name" '
			{ u = $5; sub(".*/", "", u); if (u == n && !v) v = $3 } END { print v }')
		echo ""
		if [ -n "$pinned" ]; then
			echo "    that is the release catalog/bundles.tsv pins ($(printf '%s' "$pinned" | tr '_' '.')) - nothing newer."
		else
			echo "    NOT in catalog/bundles.tsv - HP is offering something newer than this repo knows."
			echo "    Either fetch that URL directly, or update catalog/bundles.tsv."
		fi
	fi
	exit 0
fi

# HP can delete these files at any time; check before offering anything
bundle_is_served() {
	local url code
	url=$(field "$BUNDLE" 5)
	code=$(/usr/bin/curl -sIL --max-time 20 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
	if [ "$code" = "200" ]; then
		echo "==> HP is still serving it: $(basename "$url")"
		return 0
	fi
	echo "HP is no longer serving that bundle (HTTP $code):" >&2
	echo "  $url" >&2
	echo "Try ./fetch-driver.sh --check to see what HP does still offer." >&2
	return 1
}

# which installer to use; ROUTE is set to hp, light or none
ask_route() {
	local reply
	if [ ! -t 0 ] || [ ! -t 1 ]; then
		ROUTE=none
		return 0
	fi
	printf "Install which way? [Y] HP's own installer / [l] light install, queue included / [n] neither: "
	read -r reply || reply=""
	case "$reply" in
		[lL]*) ROUTE=light ;;
		[nN]*) ROUTE=none ;;
		*)     ROUTE=hp ;;   # Enter or y: HP's installer
	esac
}

# sets BUNDLE from the attached printer (device id, else the device URI); prints as it goes
detect_bundle() {
	local line mdl des short model patterns
	line=$(lpinfo -l -v 2>/dev/null | awk '/device-id/ && /MDL:/ && !l { l = $0 } END { print l }')
	patterns=""
	if [ -n "$line" ]; then
		mdl=$(printf '%s' "$line" | sed -n 's/.*MDL:\([^;]*\).*/\1/p')
		des=$(printf '%s' "$line" | sed -n 's/.*DES:\([^;]*\).*/\1/p')
		short=$(printf '%s' "$des" | awk '{ print $NF }')
		echo "==> Detected: ${des:-unknown} (family: ${mdl:-unknown})"
		patterns="$(printf '%s\n%s\n%s\n' "$mdl" "$des" "$short")"
	else
		model=$({ lpinfo -v 2>/dev/null; lpstat -v 2>/dev/null; } |
			sed -n 's|.*usb://[^/]*/\([^?]*\).*|\1|p' | sed 's/%20/ /g' | sed -n '1p')
		[ -n "$model" ] || return 1
		echo "==> Detected (from device URI): $model"
		patterns="$model"
	fi

	while IFS= read -r pattern; do
		[ -n "$pattern" ] || continue
		if search "$pattern"; then
			BUNDLE=$(printf '%s' "$BUNDLES" | sed -n '1p')
			[ -n "$BUNDLE" ] || return 1
			echo ""
			echo "    -> bundle $BUNDLE"
			return 0
		fi
	done <<< "$patterns"
	return 1
}

if [ "$MINE" = 1 ]; then
	# best case: the CUPS usb backend can read the printer's IEEE 1284 device id
	line=$(lpinfo -l -v 2>/dev/null | awk '/device-id/ && /MDL:/ && !l { l = $0 } END { print l }')
	patterns=""
	if [ -n "$line" ]; then
		mdl=$(printf '%s' "$line" | sed -n 's/.*MDL:\([^;]*\).*/\1/p')
		des=$(printf '%s' "$line" | sed -n 's/.*DES:\([^;]*\).*/\1/p')
		short=$(printf '%s' "$des" | awk '{ print $NF }')
		echo "==> Detected: ${des:-unknown} (family: ${mdl:-unknown})"
		patterns="$(printf '%s\n%s\n%s\n' "$mdl" "$des" "$short")"
	else
		# the printer may be asleep, or already claimed by a queue: the URI still names it
		model=$({ lpinfo -v 2>/dev/null; lpstat -v 2>/dev/null; } |
			sed -n 's|.*usb://[^/]*/\([^?]*\).*|\1|p' | sed 's/%20/ /g' | sed -n '1p')
		[ -n "$model" ] || die "no USB printer found on this machine"
		echo "==> Detected (from device URI): $model"
		patterns="$model"
	fi

	# read line by line: word splitting would search "HP", "LaserJet", "M101-M106" separately
	while IFS= read -r pattern; do
		[ -n "$pattern" ] || continue
		if search "$pattern"; then
			echo ""
			echo "    -> fetch it with:  ./fetch-driver.sh --bundle $(printf '%s' "$BUNDLES" | sed -n '1p')"
			exit 0
		fi
	done <<< "$patterns"
	die "no driver for that printer in HP's remaining bundles"
fi

if [ -n "$FIND" ]; then
	echo "==> Matches for '$FIND':"
	search "$FIND" || die "nothing matched '$FIND'"
	echo ""
	if [ "$(printf '%s\n' "$BUNDLES" | wc -l | tr -d ' ')" = 1 ]; then
		BUNDLE="$BUNDLES"
		if [ "$SHOW_URL" = 1 ]; then
			field "$BUNDLE" 5
			exit 0
		fi
		if [ "$ACTION" = fetch ]; then
			act
		else
			echo "    -> bundle $BUNDLE"
			echo "       fetch it with:  ./fetch-driver.sh --bundle $BUNDLE"
		fi
	else
		echo "    -> several bundles match (${BUNDLES//$'\n'/ }); pick one with --bundle"
	fi
	exit 0
fi

if [ "$SHOW_URL" = 1 ] && [ -n "$BUNDLE" ]; then
	field "$BUNDLE" 5
	exit 0
fi

if [ -n "$BUNDLE" ]; then
	act
	exit 0
fi

if [ "$INSTALL" = yes ] && [ -d "$HERE/driver/root" ]; then
	install_now
	exit 0
fi

# nothing actionable was asked for: do the whole thing for the attached printer
if [ -z "$BUNDLE" ] && [ -z "$FIND" ] && [ "$MINE" = 0 ] && [ "$CHECK" = 0 ] \
   && [ "$LIST" = 0 ] && [ "$SHOW_URL" = 0 ] && [ "$INSTALL" != yes ]; then
	if detect_bundle; then
		echo ""
		bundle_is_served || exit 1
		if [ "$DRY_RUN" = 1 ]; then
			echo "    would offer: [Y] HP's own installer - download $(field "$BUNDLE" 4 | awk '{ printf "%.0f", $1/1e6 }') MB and open it"
			echo "                 [l] light install - fetch ~23 MB into driver/root, then sudo ./install.sh"
			exit 0
		fi
		ROUTE=hp
		ask_route
		case "$ROUTE" in
			hp)    HP_INSTALLER=1; open_hp_installer ;;
			light) INSTALL=yes; fetch ;;
			none)  echo "Nothing done. To just fetch it:  ./fetch-driver.sh --bundle $BUNDLE" ;;
		esac
		exit 0
	fi
	echo "No printer found to work from - is it plugged in and awake?"
	echo ""
fi

usage
