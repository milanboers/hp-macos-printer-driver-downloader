#!/usr/bin/env python3
"""
Pulls driver sub-packages out of an HP macOS "printer essentials" .pkg without downloading the
whole thing.

An HP bundle is 300-500 MB, but the printing driver inside it is 15-60 MB. This reads the xar
table of contents (a few KB at the start of the archive) to find out where the sub-packages live,
then fetches just those with HTTP range requests. Every fetched byte is checked against the sha1
in HP's own table of contents, so a short read or a mangled response fails loudly.

    tools/hp-fetch.py --url URL --pkgs com.hp.print.epcl.driver.pkg,... --dest driver/root
"""
import argparse
import bz2
import os
import hashlib
import pathlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

BASE = "https://ftp.hp.com/pub/softlib/software12/HP_Quick_Start/osx/Installations/Essentials"


def tool(name):
    """the macOS-provided binary, not whatever PATH has first.

    Homebrew's coreutils puts a GNU chmod/ditto-lookalike on PATH, and GNU chmod fails with
    "Operation not permitted" on these trees on APFS, which killed the merge step.
    """
    for directory in ("/usr/bin", "/bin", "/usr/sbin", "/sbin"):
        candidate = os.path.join(directory, name)
        if os.path.exists(candidate):
            return candidate
    return name


def rng(url, start, end, attempts=3):
    last = ""
    for _ in range(attempts):
        out = subprocess.run(
            [tool("curl"), "-sfL", "--max-time", "600", "--retry", "2", "-r", f"{start}-{end}", url],
            capture_output=True)
        if out.returncode == 0 and out.stdout:
            return out.stdout
        last = out.stderr.decode("utf-8", "replace").strip()
    raise RuntimeError(f"range {start}-{end} of {url} failed: {last}")


def get_toc(url):
    head = rng(url, 0, 27)
    magic, header_size, _ver, toc_comp, _toc_uncomp, _cksum = __import__("struct").unpack(
        ">4sHHQQI", head)
    if magic != b"xar!":
        raise RuntimeError(f"{url} is not a xar archive")
    toc = ET.fromstring(zlib.decompress(rng(url, header_size, header_size + toc_comp - 1)))
    # data offsets in the TOC are relative to the heap, which starts right after the TOC
    return toc, header_size + toc_comp


def walk(node, prefix=""):
    for child in node.findall("file"):
        name = child.findtext("name") or ""
        path = f"{prefix}/{name}" if prefix else name
        yield child, path
        yield from walk(child, path)


def toc_index(toc, heap_base):
    idx = {}
    for node, path in walk(toc.find("toc")):
        data = node.find("data")
        if data is None:
            continue
        checksum = data.find("archived-checksum")
        idx[path] = {
            "offset": heap_base + int(data.findtext("offset") or 0),
            "length": int(data.findtext("length") or 0),
            "sha1": checksum.text.strip() if checksum is not None and checksum.text else None,
        }
    return idx


def fetch_verified(url, entry, label):
    data = rng(url, entry["offset"], entry["offset"] + entry["length"] - 1)
    if len(data) != entry["length"]:
        raise RuntimeError(f"{label}: got {len(data)} bytes, expected {entry['length']}")
    if entry["sha1"]:
        got = hashlib.sha1(data).hexdigest()
        if got != entry["sha1"]:
            raise RuntimeError(f"{label}: sha1 {got} != {entry['sha1']}")
    return data


def decompress(data):
    """xar payloads and plists are stored gzip or bzip2 compressed, or not at all"""
    if data[:2] == b"\x1f\x8b":
        return zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(data)
    if data[:3] == b"BZh":
        return bz2.decompress(data)
    return data


def run(cmd, **kwargs):
    """run a helper, and on failure say what it actually complained about"""
    try:
        return subprocess.run(cmd, check=True, **kwargs)
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or b"").decode("utf-8", "replace").strip()
        raise RuntimeError(f"{cmd[0]} failed on {cmd[-1]}: {detail or exc}") from exc


def install_location(pkginfo):
    match = re.search(r'install-location="([^"]*)"', decompress(pkginfo).decode("utf-8", "replace"))
    return match.group(1) if match else "/"


def clear(dest):
    """empty the destination: modes first (HP ships 555), then unlink (provenance allows that)"""
    if not os.path.exists(dest):
        return
    run([tool("chmod"), "-R", "u+w", dest], capture_output=True)
    run([tool("rm"), "-rf", dest], capture_output=True)


def extract(url, pkgs, dest, quiet=False, dry_run=False, fresh=False):
    toc, heap_base = get_toc(url)
    idx = toc_index(toc, heap_base)
    fetched = 0

    if fresh and not dry_run:
        clear(dest)

    if dry_run:
        for pkg in pkgs:
            payload = idx.get(f"{pkg}/Payload")
            if not payload or not payload["length"]:
                print(f"  ! {pkg}: no payload in this archive", file=sys.stderr)
                continue
            fetched += payload["length"]
            print(f"  would fetch {pkg}  {payload['length']/1e6:6.1f} MB")
        return fetched

    for pkg in pkgs:
        payload = idx.get(f"{pkg}/Payload")
        if not payload or not payload["length"]:
            print(f"  ! {pkg}: no payload in this archive, skipping", file=sys.stderr)
            continue

        location = "/"
        pkginfo = idx.get(f"{pkg}/PackageInfo")
        if pkginfo and pkginfo["length"]:
            location = install_location(fetch_verified(url, pkginfo, f"{pkg}/PackageInfo"))

        raw = fetch_verified(url, payload, f"{pkg}/Payload")
        fetched += len(raw)

        with tempfile.TemporaryDirectory() as tmp:
            blob = pathlib.Path(tmp, "Payload")
            blob.write_bytes(raw)
            unpacked = pathlib.Path(tmp, "unpacked")
            unpacked.mkdir()
            # payloads are compressed cpio; bsdtar sniffs the format and restores dir modes last
            subprocess.run(["tar", "-xf", str(blob), "-C", str(unpacked)],
                           check=True, capture_output=True)
            target = pathlib.Path(dest + location.rstrip("/"))
            target.mkdir(parents=True, exist_ok=True)
            # earlier payloads leave read-only directories behind (that is what HP's archive says),
            # which would stop this merge from creating anything underneath them
            run([tool("chmod"), "-R", "u+w", str(target)], capture_output=True)
            run([tool("chmod"), "-R", "u+w", str(unpacked)], capture_output=True)
            run([tool("ditto"), str(unpacked), str(target)], capture_output=True)

        if not quiet:
            print(f"  {pkg}  {len(raw)/1e6:6.1f} MB -> {target}")

    return fetched


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True)
    ap.add_argument("--pkgs", required=True, help="comma separated sub-package names")
    ap.add_argument("--dest", default="driver/root")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--fresh", action="store_true",
                    help="empty the destination first instead of merging into it")
    args = ap.parse_args()

    pkgs = [p for p in args.pkgs.split(",") if p]
    try:
        fetched = extract(args.url, pkgs, args.dest, args.quiet, args.dry_run, args.fresh)
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"  fetched {fetched/1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
