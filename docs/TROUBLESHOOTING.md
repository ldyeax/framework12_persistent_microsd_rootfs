# Troubleshooting

## The live SCSI flags are missing

The matching reader must report all four flags in its sysfs `blacklist` file:

```text
INQUIRY_36 IGN_MEDIA_CHANGE SKIP_IO_HINTS RETRY_MEDIA_CHANGE
```

If `RETRY_MEDIA_CHANGE` is absent, first check `uname -r`. Common causes are
booting the fallback kernel, installing the image under a different release
than its modules, building an unpatched source tree, or selecting the wrong
boot entry.

If none of the exact-device flags appear, print the inquiry fields without
stripping meaningful internal spaces:

```bash
for device in /sys/class/scsi_device/*/device; do
    printf '%s vendor=%q model=%q rev=%q flags=%q\n' \
        "${device%/device}" \
        "$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' < "$device/vendor")" \
        "$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' < "$device/model")" \
        "$(tr -d '[:space:]' < "$device/rev")" \
        "$(cat "$device/blacklist" 2>/dev/null || true)"
done
```

Do not weaken the table match merely to make an unknown reader receive the
quirk. Capture diagnostics and establish that it has the same failure first.

## A patch does not apply

Patch 2 must follow patch 1. Check whether the series is already present:

```bash
git apply --reverse --check patches/0002-scsi-retry-quirked-media-change.patch
git apply --reverse --check patches/0001-scsi-sd-handle-framework-microsd-resume.patch
```

On a new kernel, an apply failure is protective. Inspect for:

- an upstream equivalent or existing Framework entry;
- a new assignment at bit 35 in `include/scsi/scsi_devinfo.h`;
- changed SCSI resume, completion, or TEST UNIT READY code;
- a vendor patch that changes the same context.

Do not use fuzz, reject files, or a blind context edit. Rebase the semantics,
give the build a new release suffix, and repeat the complete validation.

`drivers/scsi/scsi_devinfo_tbl.c` is a generated target and should not be in
the patch. Its flag-name entry is generated from `scsi_devinfo.h`.

## Portage did not apply the files

Confirm the exact paths and checksums:

```bash
sudo find /etc/portage/patches/sys-kernel/gentoo-sources -maxdepth 1 -type f -print
(cd patches && sha256sum -c SHA256SUMS)
```

The source tree must be freshly prepared after the user patches are installed.
Do not manually apply them to a tree Portage has already patched. Review emerge
output and logs for `eapply_user` failures.

## The new kernel does not boot from USB

Boot the fallback and inspect the failed release. Frequent causes are:

- wrong `root=UUID=` or filesystem type;
- missing `rootwait` or an initramfs that does not wait for USB;
- xHCI, USB storage, SCSI disk, partition, or filesystem support missing from
  both the kernel and initramfs;
- initramfs built from the wrong `/lib/modules/<release>` tree;
- omitted `LOCALVERSION` during `modules_install` or `install`;
- `/boot` or the ESP was not mounted during installation;
- stale bootloader paths;
- missing Secure Boot signatures.

Built-in root-path drivers avoid many ordering failures. If they are modular,
use the initramfs inspection tool for the distribution and verify the exact
module set and release.

## `validate-resume.sh --check` refuses to run

The script deliberately stops if:

- it is not root;
- `/` is not writable or is not a directly resolvable block source;
- the exact reader is not in the `lsblk` ancestor chain for `/`;
- any of the four live flags is missing;
- `mem` sleep or a usable RTC is unavailable;
- another RTC alarm is pending;
- the current-boot systemd kernel journal cannot be read;
- its fsynced probe cannot be created on `/`.

Resolve the specific preflight failure. Do not bypass a guard merely to obtain
a PASS line. Device-mapper and LVM roots should normally appear in the
`lsblk -s` chain; unusual storage stacks may require a reviewed extension to
the ancestry check.

## The machine wakes immediately

`rtcwake` sets a deadline; it does not disable other wake sources. The script
reports a cycle as early when elapsed time is less than 80% of the requested
interval. An early transition still crosses the kernel storage resume path,
but it is not evidence for a long sleep.

Inspect platform wake sources and supplement the automated run with lid-close
and longer sleeps. Direct `rtcwake` does not execute every desktop or lid-policy
hook. Do not disable wake sources without understanding whether they are needed
for the keyboard, lid, power button, or safety devices.

## Unit Attention still appears

A successfully retried Unit Attention may be logged without a block I/O
failure, although the normal retry path is usually quiet. Treat any of these
as a failed validation:

- `device offline or changed`;
- `rejecting I/O to offline device`;
- an I/O or writeback error for the reader or root partition;
- an XFS metadata, log, corruption, or forced-shutdown message;
- a failed post-resume write or fsync.

Capture `scripts/collect-diagnostics.sh` output and the complete kernel journal
around the cycle. Confirm the sense tuple: normal I/O retry handles only
current `UNIT_ATTENTION 28/00` on the exact quirked device. See the patch notes
for the TEST UNIT READY polling semantics.

## The USB reader disconnects or resets

A log showing USB disconnect, new device enumeration, xHCI timeout, controller
reset, or repeated transport reset is a different failure mode. The SCSI retry
quirk cannot preserve a mounted filesystem across actual device loss. Check
firmware, physical seating, USB persistence, power policy, and hardware, and
do not describe that result as fixed by this series.

## Out-of-tree module warnings

Rebuild every module required for boot against the new release before creating
the initramfs. A warning about an optional subsystem is nonfatal only after
confirming the root and boot path do not require it. For example, a missing ZFS
module is irrelevant to an XFS root only if no boot-critical pool depends on
ZFS.

## Filesystem errors remain from an earlier failure

Stop suspend testing and use the [recovery procedure](RECOVERY.md). A kernel
fix prevents the identified future error path; it does not repair existing
filesystem damage.
