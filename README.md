# Persistent microSD root on the Framework Laptop 12

This repository contains an out-of-tree Linux SCSI workaround and the
operational procedure used to make a Framework MicroSD (2nd Gen) Expansion
Card reliable as the root filesystem across suspend and resume.

> [!CAUTION]
> The patch gives the matching reader fixed-media semantics for one specific
> media-change response. Never remove or replace the root card while Linux is
> running or suspended. Keep a current backup, rescue media, and a known-good
> fallback kernel.

## Scope

The workaround has been exercised on this exact path:

| Component | Tested value |
| --- | --- |
| Computer | Framework Laptop 12, Intel, x86_64 |
| Expansion card | Framework MicroSD (2nd Gen) |
| USB identity | `32ac:0026` |
| SCSI inquiry | vendor `FRMW`, model `MicroSD(2nd Gen)`, revision `0001` |
| Transport | USB Bulk-Only (`usb-storage`), not MMC and not UAS |
| Root filesystem | XFS on a partition of the reader's SCSI disk |
| Kernel | `6.18.33-gentoo-r1-fw12-sdroot1` |
| Firmware observed | Framework Laptop 12 BIOS 3.07 |
| Suspend path | s2idle (`rtcwake --mode mem`) |

The device-table match covers every revision reporting the exact SCSI vendor
and model above. Other Framework readers, other inquiry strings, hibernation,
and S3/deep sleep have not been validated.

## Confirmed result

On 2026-07-18, the patched kernel completed 20 suspend/resume transitions in
the same session that remained in use afterward. The current boot contained:

- 20 kernel suspend entries and 20 exits;
- all four expected SCSI flags: `INQUIRY_36`, `IGN_MEDIA_CHANGE`,
  `SKIP_IO_HINTS`, and `RETRY_MEDIA_CHANGE`;
- no `UNIT ATTENTION 28/00`, block I/O, changed-device, or XFS shutdown errors;
- a successful read-only online `xfs_scrub -n -k /` with no corruption or
  repair requirement.

Six RTC cycles remained asleep for approximately the requested 15 seconds;
14 woke early because of another wake source. All 20 still crossed the kernel
suspend/resume path. Use real lid-close tests and longer sleeps in addition to
the automated test.

## Quick start on Gentoo

Read [the Gentoo procedure](docs/GENTOO.md) completely before changing a
bootable kernel. The condensed flow is:

```bash
sudo ./scripts/install-gentoo-patches.sh
```

Let a fresh `sys-kernel/gentoo-sources` install or reinstall apply the files
from `/etc/portage/patches/sys-kernel/gentoo-sources/`. Configure a uniquely
named kernel with the USB, SCSI, root-filesystem, and suspend drivers built in
or guaranteed in its initramfs. Build and install without overwriting the
fallback kernel, reboot, then check the live quirk flags:

```bash
uname -r

for device in /sys/class/scsi_device/*/device; do
    printf '%s / %s / %s: ' \
        "$(tr -d ' ' < "$device/vendor")" \
        "$(sed 's/[[:space:]]*$//' < "$device/model")" \
        "$(tr -d ' ' < "$device/rev")"
    cat "$device/blacklist"
done
```

After confirming that the Framework reader has all four flags, run the guarded
test from a local or otherwise persistent session:

```bash
sudo ./scripts/validate-resume.sh 20 15
```

The command needs `bash`, util-linux (`findmnt`, `lsblk`, `flock`, and
`rtcwake`), coreutils, and a readable systemd kernel journal. It writes and
fsyncs a temporary probe on `/` after every resume. It does not exercise lid
policy or desktop suspend hooks.

## What the patches fix

The reader stays enumerated over suspend, but after some resumes reports SCSI
`UNIT ATTENTION`, ASC/ASCQ `28/00`: not-ready to ready transition, medium may
have changed. Linux normally gives removable media real media-change
semantics. It fails the first request, marks the device changed, and rejects
following I/O until polling clears that state. That is destructive when the
device contains the mounted root filesystem and can make XFS shut down.

The two patches apply in order:

1. Extend the existing `BLIST_IGN_MEDIA_CHANGE` sense clear into the system
   resume path and add the exact SCSI inquiry match.
2. Add `BLIST_RETRY_MEDIA_CHANGE` for the reader. The normal I/O completion
   path retries only current-sense `UNIT_ATTENTION 28/00`; removable-media
   polling suppresses the changed flag for the same normalized sense tuple.
   The exact device entry also preserves `SKIP_IO_HINTS`.

The eager resume clear handles an already-present condition before tasks thaw.
The narrowly scoped completion retry handles the observed race where the
reader produces the condition about half a second later. Other devices and
other sense codes keep their normal behavior.

See [the root-cause analysis](docs/ROOT-CAUSE.md) for the evidence and code
path, and [the patch notes](patches/README.md) for applicability limits.

## Existing kernel parameters

The successful test retained this conservative command-line setup:

```text
rootwait rootfstype=xfs usbcore.autosuspend=-1 \
usb-storage.quirks=32ac:0026:u usbcore.quirks=32ac:0026:k
```

These flags are not substitutes for the SCSI patches. `rootwait` covers
asynchronous root-device discovery. Disabling USB autosuspend and link power
management can remove other power-state variables. The `u` flag disables UAS,
but this reader already uses Bulk-Only transport. Keep the tested command line
for initial validation, then change one variable at a time if simplifying it.

## Repository contents

- [`patches/`](patches/) contains the ordered kernel patches and checksums.
- [`docs/GENTOO.md`](docs/GENTOO.md) is the tested Gentoo installation path.
- [`docs/GENERIC-LINUX.md`](docs/GENERIC-LINUX.md) covers distro-neutral build
  and early-boot requirements.
- [`docs/ROOT-CAUSE.md`](docs/ROOT-CAUSE.md) records the investigation and patch
  mechanics.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) covers mismatches,
  upgrade conflicts, and validation failures.
- [`docs/RECOVERY.md`](docs/RECOVERY.md) covers fallback boot and XFS recovery.
- [`scripts/collect-diagnostics.sh`](scripts/collect-diagnostics.sh) collects
  relevant state without intentionally printing storage serial numbers.
- [`scripts/validate-resume.sh`](scripts/validate-resume.sh) runs guarded resume
  and root-write tests.

## Licensing

Documentation and helper scripts are covered by the repository's MIT
[`LICENSE`](LICENSE). The kernel patches contain and modify Linux kernel code
and are provided under GPL-2.0-only; see [`LICENSES/GPL-2.0`](LICENSES/GPL-2.0).

## Primary references

- [Linux USB persistence documentation](https://docs.kernel.org/driver-api/usb/persist.html)
- [Linux USB power-management documentation](https://docs.kernel.org/driver-api/usb/power-management.html)
- [Linux kernel parameter reference](https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html)
- [Earlier Linux SCSI REQUEST SENSE workaround discussion](https://lkml.iu.edu/2106.3/05387.html)
- [T10 Unit Attention clarification 06-264r2](https://www.t10.org/ftp/t10/document.06/06-264r2.pdf)
- [Framework Laptop 12 BIOS releases](https://knowledgebase.frame.work/framework-laptop-12-bios-and-driver-releases-13th-gen-intel-core-HyrqeX2ex)
