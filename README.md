# HP printer driver downloader for macOS

Finds and downloads the newest macOS print drivers HP published for the 189 models it shipped as
PPDs — the *HP Printer Essentials* 5.20.0.1 release, built for macOS 26 and dated 2025-11-06, in
seven bundles. These are the drivers **HP Easy Start can no longer deliver and hp.com no longer
links to**: nothing on HP's website points at them.

## Quick start

Plug the printer in first — with no arguments the script reads its own ID to work out which bundle
it needs (not required for `--bundle`, `--product` or `--ppd`).

```sh
./fetch-driver.sh       # for the printer you have attached: find its bundle, then ask how to
                        # install it - Enter takes HP's own installer
```

It checks HP is still serving that bundle before offering anything, so the question is never asked
about a download that would fail — then it asks which way to install. The two answers are two ends of
the same job:

* **`[Y]`, or just Enter** — HP's own installer: downloads the whole bundle (313–364 MB), opens it,
  and HP's installer puts the driver in place. It installs no print queue, so **you add the printer
  yourself afterwards**: System Settings → Printers & Scanners → `+`, where the driver now shows up
  under its family name (e.g. `HP LaserJet M101-M106`). It is the route to use for the inkjet
  bundles (D, G, H, K, L, R): their filters and print-dialog extensions are laid out differently, and
  `install.sh` has not been tested against them.
* **`[l]`** — the light install: fetches only the sub-packages that printer's driver lives in, using
  HTTP range requests, verifies every byte against the sha1 in HP's own notarized archive, then runs
  `sudo ./install.sh`: ~23 MB into `/Library/Printers`, **and it creates the queue for you**, so there
  is nothing to add afterwards. Undone with `./uninstall.sh`. Verified for the LaserJets (bundle B).

No printer attached, or you want a different one?

```sh
./fetch-driver.sh --mine                # only find the bundle for the attached printer
./fetch-driver.sh --product "M102a"     # choose by model name  (--find searches, --list shows all)
./fetch-driver.sh --bundle B            # choose by bundle letter
./fetch-driver.sh --check               # ask HP's catalogue whether anything newer exists at all
```

`--install` does the light install without asking — on its own it installs whatever is already in
`driver/root` — `--no-install` fetches only, `--hp-installer` goes straight to HP's installer, and
`--dry-run` previews either route. `--help` lists the rest (`--dest`, `--with-pde`, `--with-utility`,
`--fresh`, `--url`).

Verified on macOS 27.0.1 on Apple Silicon. The drivers are HP's macOS 26 build, universal
(arm64 + x86_64), with nothing running under Rosetta.

## The problem

**1. HP's installer no longer delivers a driver for these printers.** HP Easy Start does not decide
anything itself: it asks HP's software catalogue what to install for the running macOS version, and
for these printers the answer is `NOT SUPPORTED` — on macOS 26.x as much as on 27:

```
OS=macOS 26.0    -> NOT SUPPORTED      OS=macOS 27.0    -> NOT SUPPORTED
OS=macOS 26.5    -> NOT SUPPORTED      OS=macOS 27.0.1  -> NOT SUPPORTED
OS=macOS 15.7    -> NOT SUPPORTED      OS=macOS 12.7    -> NOT SUPPORTED
```

Only legacy OS strings still resolve: `macOS 10.15`, `macOS 11.0`, `macOS 12.0`, and, oddly, the bare
`macOS 26` — so `macOS 26.5` is refused while plain `macOS 26` hands over the bundle. That lookup has
plainly not been maintained, and the dates agree: the newest release HP published for these printers
is dated **2025-11-06**, there is no `macOS27` directory on its server, and no later point release
either. Asked directly, HP's catalogue still offers exactly what this repo pins — `--check` prints
`newest offered : 5.20.0.1`.

HP's guidance for Macs is AirPrint rather than HP drivers
([HP support](https://support.hp.com/us-en/document/ish_6684477-6684524-16)) — and not every printer can
do AirPrint.

**2. Apple ships no HP drivers either.** On a current macOS install the only PPDs present are
Apple's own `Generic.ppd`, `GenericPrinter.ppd` and `AirPrint.ppd`, and `lpinfo -m` offers nothing
but Apple's sample ASCII/PCL/PostScript drivers. For a host-based HP printer those cannot work:
what macOS reads off a LaserJet Pro M102a is

```
SERN:<serial>;MFG:HP;CMD:PJL,PML,URP;MDL:HP LaserJet M101-M106;CLS:PRINTER;DES:HP LaserJet M102a;
MEM:MEM=112MB;PRN:G3Q34A;COMMENT:RES=600x1;LEDMDIS:USB#ff#04#01;
CID:HPLJPCLMSMV1;IPP-E:FF-04-01,...;MCT:PR;MCL:FL;MCV:1.0;
```

There is no PCL and no PostScript in `CMD:`, so there is nothing for a generic driver to send.
`CID:HPLJPCLMSMV1` says it wants HP's `hbpl1`/PCLm raster. It does speak IPP, but only on its vendor
USB interface (`IPP-E:FF-04-01`), never `_ippusb._tcp`, so driverless printing is not available
either.

**3. The driver itself is fine.** It exists, HP still hosts it, it is signed by HP and notarized by
Apple, and it runs on macOS 27 — universal, arm64 included, no Rosetta. HP's own installer would
happily install it if anything could still find it. That is the whole problem: not a broken driver,
a *missing pointer*. The printer looks like a brick and the only symptom is "no driver available".

This repo is that pointer. It knows the bundle for each model, and fetches the driver out of it.

## Supported printers

189 print drivers, naming 271 models, in the seven *HP Printer Essentials* bundles — PPDs plus CUPS
filters, installed by HP Easy Start:

| bundle | print drivers | named models |
| --- | --- | --- |
| B (LaserJet) | 10 | 54 |
| D (DeskJet / ENVY / OfficeJet) | 45 | 45 |
| G (OfficeJet / Photosmart) | 42 | 56 |
| H (OfficeJet Pro) | 16 | 18 |
| K (Deskjet / Photosmart) | 19 | 36 |
| L (DeskJet / Ink Tank / Smart Tank) | 39 | 42 |
| R (mobile / older OfficeJet) | 18 | 20 |

<details>
<summary>All 271 model names, by bundle</summary>

*HP's PPDs are per series — `HP DeskJet 3830 series` covers 3830–3834 — so a model can be covered
without being named.*

**Bundle B** — 313 MB

- HP Color LaserJet Pro MFP M176
- HP Color LaserJet Pro MFP M176n
- HP Color LaserJet Pro MFP M176nb
- HP Color LaserJet Pro MFP M176nr
- HP Color LaserJet Pro MFP M176ns
- HP Color LaserJet Pro MFP M176nx
- HP Color LaserJet Pro MFP M176ny
- HP Color LaserJet Pro MFP M176nz
- HP Color LaserJet Pro MFP M177
- HP Color LaserJet Pro MFP M177fb
- HP Color LaserJet Pro MFP M177fr
- HP Color LaserJet Pro MFP M177fs
- HP Color LaserJet Pro MFP M177fw
- HP Color LaserJet Pro MFP M177fx
- HP Color LaserJet Pro MFP M177fy
- HP Color LaserJet Pro MFP M177fz
- HP LaserJet M101-M106
- HP LaserJet M109-M112
- HP LaserJet M109a
- HP LaserJet M110a
- HP LaserJet M111a
- HP LaserJet M112a
- HP LaserJet M14-M17
- HP LaserJet MFP M129-M134
- HP LaserJet MFP M28-M31
- HP LaserJet Pro MFP M125-M126
- HP LaserJet Pro MFP M125a
- HP LaserJet Pro MFP M125nw
- HP LaserJet Pro MFP M125r
- HP LaserJet Pro MFP M125ra
- HP LaserJet Pro MFP M125rnw
- HP LaserJet Pro MFP M126a
- HP LaserJet Pro MFP M126nw
- HP LaserJet Pro MFP M126ny
- HP LaserJet Pro MFP M126nz
- HP LaserJet Pro MFP M127-M128
- HP LaserJet Pro MFP M127fn
- HP LaserJet Pro MFP M127fp
- HP LaserJet Pro MFP M127fs
- HP LaserJet Pro MFP M127fw
- HP LaserJet Pro MFP M127fx
- HP LaserJet Pro MFP M128fn
- HP LaserJet Pro MFP M128fp
- HP LaserJet Pro MFP M128fr
- HP LaserJet Pro MFP M128fw
- HP LaserJet Pro MFP M128fy
- HP LaserJet Pro MFP M128fz
- HP LaserJet Pro MFP M25-M27
- HP LaserJet Pro MFP M25a
- HP LaserJet Pro MFP M25nw
- HP LaserJet Pro MFP M26a
- HP LaserJet Pro MFP M26nw
- HP LaserJet Pro MFP M27c
- HP LaserJet Pro MFP M27cnw

*Also matched by HP's printer-icon names: M102a, M106w, M14-M17, MFP M125-M126, MFP M127-M128, MFP M130a, MFP M130fn, MFP M134a, MFP M134fn, MFP M176, MFP M177, MFP M25-M27, MFP M28-M31.*

**Bundle D** — 338 MB

- HP Deskjet 3540 series
- HP Deskjet 4510 series
- HP DeskJet 4530 series
- HP Deskjet 4640 series
- HP DeskJet 4670 series
- HP DeskJet 5000 series
- HP DeskJet 5200 series
- HP DeskJet 5570 series
- HP DeskJet 5640 series
- HP Deskjet D5500 series
- HP Deskjet D730
- HP Deskjet F2400 series
- HP Deskjet F4400 series
- HP Deskjet F4500 series
- HP Deskjet F735
- HP Deskjet Ink Advant K209a-z
- HP Envy 100 D410 series
- HP ENVY 110 series
- HP ENVY 120 series
- HP ENVY 4500 series
- HP ENVY 4510 series
- HP ENVY 4520 series
- HP ENVY 5000 series
- HP ENVY 5530 series
- HP ENVY 5540 series
- HP ENVY 5640 series
- HP ENVY 5660 series
- HP ENVY 7640 series
- HP ENVY Photo 6200 series
- HP ENVY Photo 7100 series
- HP ENVY Photo 7800 series
- HP Officejet 4400 K410
- HP Officejet 4500 G510a-f
- HP Officejet 4500 G510g-m
- HP Officejet 4500 G510n-z
- HP Officejet 4500 K710
- HP Officejet 4630 series
- HP OfficeJet 4650 series
- HP OfficeJet 5200 series
- HP Officejet 5740 series
- HP Officejet 8040 series
- HP Photosmart C4600 series
- HP Photosmart C4700 series
- HP Photosmart D110 series
- HP Photosmart Ink Adv K510

*Also matched by HP's printer-icon names: 110, 3540, 4500G510af, 4500G510gm, 4500G510nz, 4510, 4630, C4600, C4700, D110, D2500, D410, D5500, DeskJet4530series, DeskJet4670series, DeskJet5000series, DeskJet5200series, DeskJet5570series, DeskJet5640series, ENVY120, ENVY4500, ENVY4510series, ENVY4520series, ENVY5000series, ENVY5530, ENVY5540series, Envy5640, Envy5660, Envy7640, EnvyPhoto6200, EnvyPhoto7100, EnvyPhoto7800, F2400, F4200, F4400, F4500, K209az, K410, K510, OfficeJet4650series, OfficeJet5200series, Officejet5740, Officejet8040.*

**Bundle G** — 364 MB

- HP Officejet 6000 E609a
- HP Officejet 6000 E609n
- HP Officejet 6100
- Officejet 6100 ePrinter
- HP Officejet 6220
- Officejet 6220 ePrinter
- HP Officejet 6500 E709a
- HP Officejet 6500 E709n
- HP Officejet 6500 E710a-f
- HP Officejet 6500 E710n-z
- HP Officejet 6600
- Officejet 6600 e-All-in-One
- HP Officejet 6700
- Officejet 6700 Premium e-All-in-One
- HP Officejet 6800
- Officejet 6820 e-All-in-One
- HP OfficeJet 6950
- HP OfficeJet 6960
- HP Officejet 7000 E809a
- HP Officejet 7110 series
- Officejet 7110 Wide Format ePrinter
- HP Officejet 7500 E910
- HP OfficeJet 7510 series
- HP Officejet 7610 series
- Officejet 7610 Wide Format e-All-in-One
- Officejet 7610 Wide Format e-All-in-One Printer
- HP Officejet Pro 3610
- Officejet Pro 3610 Black and White e-All-in-One
- HP Officejet Pro 3620
- Officejet Pro 3620 Black and White e-All-in-One
- HP Officejet Pro 6230
- Officejet Pro 6230 ePrinter
- HP Officejet Pro 6830
- Officejet Pro 6830 e-All-in-One
- HP OfficeJet Pro 6960
- HP OfficeJet Pro 6970
- HP OfficeJet Pro 7720 series
- HP OfficeJet Pro 7730 series
- HP OfficeJet Pro 7740 series
- HP Photosmart 7510 series
- Photosmart 7520 e-All-in-One
- HP Photosmart 7520 series
- HP Photosmart B8500 series
- HP Photosmart C309a
- HP Photosmart C309a series
- HP Photosmart C5300 series
- HP Photosmart C6300 series
- HP Photosmart D7500 series
- HP Photosmart eStn C510 Japan
- HP Photosmart eStn C510 series
- HP Photosmart Prem C310 Japan
- HP Photosmart Prem C310 series
- HP Photosmart Prem C410 Japan
- HP Photosmart Prem C410 series
- HP Photosmart Prem-Web C309n-s
- HP Photosmart Premium C309g-m

*Also matched by HP's printer-icon names: 6000E609a, 6000E609n, 6500E709a, 6500E709n, 6500E710af, 6500E710nz, 7000E809a, 7500E910, 7510, 7520, B8500, C309gm, C309ns, C309x, C310, C410, C510, C5300, C6300, D7500, OfficeJet6950, OfficeJet6960, OfficeJet7510series, OfficeJet7720series, OfficeJet7730series, OfficeJet7740series, OfficeJetPro6960, OfficeJetPro6970, Officejet6100, Officejet6220, Officejet6600, Officejet6700, Officejet6800, Officejet7110series, Officejet7610series, OfficejetPro3610, OfficejetPro3620.*

**Bundle H** — 325 MB

- HP OfficeJet 8700
- HP Officejet Pro 8000 A809
- HP Officejet Pro 8100
- HP Officejet Pro 8100 N811a
- HP Officejet Pro 8500 A909a
- HP Officejet Pro 8500 A909g
- HP Officejet Pro 8500 A909n
- HP Officejet Pro 8500 A910
- HP Officejet Pro 8600
- HP Officejet Pro 8600 N911n
- HP Officejet Pro 8610
- HP Officejet Pro 8620
- HP Officejet Pro 8630
- HP Officejet Pro 8640
- HP Officejet Pro 8650
- HP Officejet Pro 8660
- HP OfficeJet Pro 8710
- HP OfficeJet Pro 8720

*Also matched by HP's printer-icon names: A809, A909, A910, OfficeJet8700, OfficeJetPro8710, OfficeJetPro8720, Pro8100, Pro8600, Pro8610, Pro8620, Pro8630, Pro8640, Pro8650, Pro8660.*

**Bundle K** — 326 MB

- Deskjet 3070 All-in-One Printer — B611a
- HP Deskjet 3070 B611 series
- Deskjet 3520 e-All-in-One Printer
- Deskjet 3520 e-All-in-One Printer series
- HP Deskjet 3520 series
- HP Deskjet 4610 series
- HP Deskjet 4620 series
- HP Deskjet 5520 series
- Deskjet 6520 e-All-in-One Printer series
- HP Deskjet 6520 series
- Deskjet Ink Advantage 3520 e-All-in-One Printer series
- Deskjet Ink Advantage 4625 e-All-in-One
- HP Officejet 4610 series
- Officejet 4620 e-All-in-One
- HP Officejet 4620 series
- Photosmart 5510 B111a
- HP Photosmart 5510 series
- Photosmart 5510d
- Photosmart 5510d B111a
- HP Photosmart 5510d series
- HP Photosmart 5520 series
- Photosmart 6510 B211a
- HP Photosmart 6510 series
- Photosmart 6520 e-All-in-One Printer series
- HP Photosmart 6520 series
- HP Photosmart B010 series
- HP Photosmart B109a
- HP Photosmart B109a-m
- HP Photosmart B109n
- HP Photosmart B109n-z
- HP Photosmart B110 series
- Photosmart B110a
- HP Photosmart B209a-m
- HP Photosmart Plus B209a-m
- HP Photosmart Plus B210 series
- HP Photosmart Wireless B109n-z

*Also matched by HP's printer-icon names: 3070, 5510, 6510, B010, B109am, B109nz, B110, B209am, B210, Deskjet3520, Deskjet4610, Deskjet5520, Deskjet6520, Officejet4610, Officejet4620, Photosmart5520, Photosmart6520.*

**Bundle L** — 327 MB

- HP AMP
- HP Deskjet 1000 J110 series
- Deskjet 1000 J110a series
- HP Deskjet 1010 series
- HP Deskjet 1050 J410 series
- HP DeskJet 1110 series
- HP DeskJet 1200 series
- HP Deskjet 1510 series
- HP Deskjet 2000 J210 series
- HP Deskjet 2020 series
- HP Deskjet 2050 J510 series
- HP DeskJet 2130 series
- HP DeskJet 2200 series
- HP DeskJet 2300 series
- HP Deskjet 2510 series
- HP Deskjet 2520 series
- HP Deskjet 2540 series
- HP DeskJet 2600 series
- HP Deskjet 2640 series
- HP Deskjet 3000 J310 series
- HP Deskjet 3050 J610 series
- HP Deskjet 3050A J611 series
- HP Deskjet 3510 series
- HP DeskJet 3630 series
- HP DeskJet 3700 series
- HP DeskJet 3830 series
- HP DeskJet 4720 series
- HP DeskJet 5730 series
- HP DeskJet 5810 series
- HP DeskJet 5820 series
- Deskjet Ink Adv 2010 K010
- HP Deskjet Ink Adv 2010 K010 series
- HP Deskjet Ink Adv 2060 K110
- Deskjet Ink Adv 2060 K110 series
- HP Ink Tank 110 series
- HP Ink Tank 310 series
- HP Ink Tank Wireless 410 series
- HP Officejet 2620 series
- HP OfficeJet 3830 series
- HP Smart Tank 350 series
- HP Smart Tank 500 series
- HP Smart Tank Wireless 450 series

*Also matched by HP's printer-icon names: 1000, 1010, 1510, 2000, 2020, 2050, 2510, 2520, 2540, 2620, 3000, 3050, 3050A, 3510, AMP, DeskJet1110series, DeskJet2130series, DeskJet2200, DeskJet2600series, DeskJet3630series, DeskJet3700, DeskJet3830series, DeskJet4720series, DeskJet5730series, DeskJet5810series, DeskJet5820series, InkTank110, InkTank310, InkTankWireless410, K010, K110, OfficeJet3830series, SmartTank350, SmartTank500, SmartTankWireless450.*

**Bundle R** — 320 MB

- HP Deskjet 460
- HP Deskjet 9800
- HP L411
- HP L511
- HP Officejet 100 Mobile L411
- HP Officejet 150 Mobile L511
- HP OfficeJet 200 Mobile Series
- HP OfficeJet 250 Mobile Series
- HP Officejet H470
- HP Officejet J3600 series
- HP Officejet J4500 series
- HP Officejet J4660 series
- HP Officejet J4680 series
- HP Officejet J5700 series
- HP Officejet J6400 series
- HP Officejet K7100
- HP Officejet Pro K5300
- HP Officejet Pro K5400
- HP Officejet Pro K8600
- HP Officejet Pro L7400

*Also matched by HP's printer-icon names: 460, 9800, H470, J3600, J4500, J4660, J4680, J5700, J6400, K5300 K5400, K7100, K8600, L411, L511, L7400, OfficeJet200MobileSeries, OfficeJet250MobileSeries.*

</details>

Out of scope is anything HP reaches by other means:

* **Plain AirPrint printing.** If AirPrint covers what you need, there is nothing to install; HP's own
  advice is AirPrint plus Apple's built-in driver.
* **Enterprise LaserJet, PageWide and Managed models.** HP documents those separately (support-site
  driver downloads; in practice PostScript/PCL and IPP Everywhere over the network), and its
  catalogue has no printer-essentials entry for them at all: asked about a LaserJet Enterprise M611dn
  or a PageWide Enterprise Color 556dn, it answers `NOT SUPPORTED`.
* **Scanners, fax, HP Smart, firmware.** Printing only, through these PPDs and filters.

## Requirements

* macOS 26 or 27.
* For the **light install** (`[l]`, and `--bundle` / `--product` / `--ppd`) and `--check`: a working
  `python3` (3.7 or newer, standard library only). On macOS `/usr/bin/python3` is a stub until the
  Xcode Command Line Tools are installed — a `xcode-select` shim, not an interpreter — so a bare
  system needs `xcode-select --install`. You very likely have that already: `git`, which you needed
  to clone this repo, comes from the same place. Verified with 3.9.6 (Command Line Tools) and 3.15
  (Homebrew), producing identical output.
* Everything else uses what macOS ships: `awk`, `grep`, `sed`, `curl`, `tar`, `ditto` and CUPS.
  `--list`, `--find`, `--mine`, HP's installer route (`[Y]`, `--hp-installer`) and `install.sh` need
  no Python at all.
* Admin rights for the install step, and the printer on USB for the commands that go looking for it.

## Installing, in detail

For driving the light install by hand, or knowing what it does:

```sh
./install.sh --dry-run       # what it would do, and which PPD it picked
sudo ./install.sh            # copies driver/root into /Library/Printers, restarts CUPS, adds a queue
sudo ./uninstall.sh          # removes exactly what install.sh added
```

It picks the PPD matching the attached printer and records what it added. `--no-queue` skips the
queue, so you add the printer yourself instead. Re-fetching replaces `driver/root` rather than merging
into it, because HP's files are read-only — `--fresh` does that explicitly for a custom `--dest`.

HP's installer, by contrast, is a signed, notarized macOS package holding all 26 packages HP shipped:
~467 MB once installed, including a 200 MB `HP EasyScan`, 147 MB of `HP Utility` and a 62 MB fax
driver.

## Limitations

* HP can delete these files at any time. The catalog pins the URLs and every fetch is checksummed
  against HP's archive, but none of this is supported by HP.
* HP's installer route is verified as far as Gatekeeper accepting the package (`spctl`: accepted,
  Notarized Developer ID) and Installer opening it. Nobody has clicked it through to a finished
  install here, so what it leaves behind is untested; the light install is the one that has been
  exercised end to end.
* Driver updates for these models appear to have stopped: the newest bundle is dated 2025-11-06 and
  there is no `macOS27`. `./fetch-driver.sh --check` tests that against HP's catalogue yourself.
* PPD-based queues are on their way out in CUPS generally
  (`lpadmin: Printer drivers are deprecated ...`), independent of this driver.

## Credits

The installation approach — a PPD in `/Library/Printers/PPDs/Contents/Resources` pointing at its
filters by absolute path, matched against the printer's device ID — follows
[str4ngeMD/m125a-native-driver](https://github.com/str4ngeMD/m125a-native-driver) (M125a, same
`hbpl1` printing path); no code was copied. The drivers themselves are HP's, fetched from HP's own
server.

## License

The scripts, tools and catalog in this repo are MIT, see [LICENSE](LICENSE). That covers our own code
and the index in `catalog/` — bundle names, versions, URLs and sizes compiled from HP's public
packages.

HP's driver files are copyright HP Development Company, L.P. and are **not** part of this repo: they
are downloaded from HP's own server at run time, and HP's licence applies to them. Nothing here
patches, strips or re-signs them — `install.sh` only checks their signatures.

HP is a trademark of HP Development Company, L.P. This project is unaffiliated: not sponsored,
authorised or endorsed by HP.
