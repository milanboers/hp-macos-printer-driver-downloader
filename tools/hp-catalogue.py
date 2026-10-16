#!/usr/bin/env python3
"""
Asks HP's software catalogue what it would install for a printer, and which version.

This is the same request HP Easy Start makes, and the same data its upgrade check compares against
(bundles are offered when the catalogue's version is newer than what is installed). So it is the
authoritative answer to "is there a newer driver than the one this repo pins?" - HP keys the entries
by model name, and the only trick is that current OS strings come back NOT SUPPORTED, so we ask with
legacy ones.

    tools/hp-catalogue.py --model "HP LaserJet M101-M106"
    tools/hp-catalogue.py --model "HP LaserJet M101-M106" --os "macOS 12.0"
"""
import argparse
import json
import subprocess
import sys
import urllib.parse

ENDPOINT = "https://h20614.www2.hp.com/ediags/solutions/software/v3"
# HP answers for these; anything version-accurate (macOS 26.5, macOS 27.0) comes back NOT SUPPORTED
LEGACY_OS = ["macOS 12.0", "macOS 11.0", "macOS 10.15", "macOS 26"]


def query(model, os_string, timeout=30):
    params = urllib.parse.urlencode({
        "lc": "en", "cc": "us", "client": "hp-quick-start",
        "ModelName": model, "OS": os_string,
    })
    out = subprocess.run(["curl", "-sfL", "--max-time", str(timeout), f"{ENDPOINT}?{params}"],
                         capture_output=True)
    if out.returncode != 0:
        raise RuntimeError(f"catalogue request failed ({out.returncode})")
    try:
        return json.loads(out.stdout.decode("utf-8", "replace"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"catalogue returned something unparseable: {exc}") from exc


def version_key(version):
    parts = []
    for chunk in (version or "").split("."):
        parts.append(int(chunk) if chunk.isdigit() else 0)
    return tuple(parts)


def components(entries):
    out = []
    for entry in entries:
        if entry.get("Type") == "NOT SUPPORTED" or not entry.get("FtpURL"):
            continue
        out.append(entry)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="the printer's family name, e.g. from lpinfo -l -v")
    ap.add_argument("--os", action="append", help=f"OS string to ask with (default: try {LEGACY_OS})")
    ap.add_argument("--all", action="store_true", help="show every component found, not just the best")
    args = ap.parse_args()

    found = {}
    for os_string in (args.os or LEGACY_OS):
        try:
            entries = query(args.model, os_string)
        except RuntimeError as exc:
            print(f"  {os_string}: {exc}", file=sys.stderr)
            continue
        for entry in components(entries):
            found[entry["FtpURL"]] = (os_string, entry)

    if not found:
        print(f"{args.model}: not supported by HP's catalogue for any OS string tried "
              f"({', '.join(args.os or LEGACY_OS)})")
        print("  (either HP stopped offering it, or the name does not match the one HP keys on - "
              "the name in the printer's MDL: field is the one that works)")
        return 1

    ranked = sorted(found.values(), key=lambda item: version_key(item[1].get("Version")), reverse=True)
    if args.all:
        print(f"{args.model}: {len(ranked)} components")
        for os_string, entry in ranked:
            print(f"  {entry.get('Version', '?'):<12} {entry['FtpURL']}   (via OS={os_string})")
        return 0

    os_string, best = ranked[0]
    print(f"{args.model}")
    print(f"  newest offered : {best.get('Version', '?')}")
    print(f"  {best['FtpURL']}")
    print(f"  (HP answered this for OS={os_string}; {len(ranked) - 1} older component(s) also offered)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
