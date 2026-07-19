# Gentoo installation

This is the installation path used for the validated Framework Laptop 12. Read
the whole procedure before starting. Kernel compilation is write-heavy, so use
AC power, verify free space, and have a current backup and bootable rescue
media. Do not suspend an unpatched kernel during the build or installation.

## 1. Keep a bootable fallback

Retain at least one current kernel, its matching module tree and initramfs, and
its bootloader entry. Use a unique release suffix for this build. Do not
overwrite the only known-good image.

Verify that `/boot` and, if separate, the EFI System Partition are mounted and
have enough space:

```bash
findmnt /boot
findmnt /boot/efi 2>/dev/null || true
df -h /boot /boot/efi 2>/dev/null
```

Know how to select the fallback from GRUB before proceeding.

## 2. Confirm the hardware path

Inspect the resolved tested profile and collect the live topology first:

```bash
./scripts/install-gentoo-patches.sh --show-config
sudo ./scripts/collect-diagnostics.sh
```

Install `sys-apps/usbutils` if `lsusb` is unavailable. The following explicit
commands show the identity used for the validated result:

```bash
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /
lsusb -d 32ac:0026
lsusb -t

for device in /sys/class/scsi_device/*/device; do
    [[ -r $device/vendor && -r $device/model ]] || continue
    printf '%s: vendor=%q model=%q rev=%q flags=%q\n' \
        "${device%/device}" \
        "$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' < "$device/vendor")" \
        "$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' < "$device/model")" \
        "$(tr -d '[:space:]' < "$device/rev")" \
        "$(cat "$device/blacklist" 2>/dev/null || true)"
done
```

With the default profile, proceed only if the root device ultimately descends
from the reader reporting USB `32ac:0026` and SCSI `FRMW` /
`MicroSD(2nd Gen)`. `lsusb -t` should show `Driver=usb-storage`, not an MMC
host. A different identity needs a separate investigation; do not broaden the
device-table match speculatively. To constrain the intended expansion bay,
record the reader's udev `ID_PATH` as described in
[device and slot configuration](CONFIGURATION.md).

Check Framework's current firmware page before the kernel work. The validated
machine used BIOS 3.07 and reader revision `0001`; those are observations, not
permanent claims about the latest available firmware.

## 3. Install persistent Portage patches

From this repository:

```bash
(cd patches && sha256sum -c SHA256SUMS)
./scripts/install-gentoo-patches.sh --show-config
sudo ./scripts/install-gentoo-patches.sh
```

This installs the ordered files under:

```text
/etc/portage/patches/sys-kernel/gentoo-sources/
```

Portage's user-patch phase will apply them when it prepares a fresh
`sys-kernel/gentoo-sources` tree. Install or reinstall the selected source
package using the normal package-management policy for the machine, and
inspect the emerge output to confirm all three patch filenames were applied.
The installer also writes the resolved runtime guards to
`/etc/framework-microsd-rootfs.conf`.

The tested values are defaults rather than fixed inputs. Pass `--config FILE`
or individual device options when they differ. `--usb-slot ID_PATH` constrains
validation to a physical expansion bay; it cannot narrow the kernel quirk.
Use `--portage-slot SLOT` only when Portage should install under a package-slot
directory such as `gentoo-sources:6.18.33-r1`. These two meanings of slot are
independent; see [the complete option reference](CONFIGURATION.md).

Do not also apply the patches manually to a tree that Portage has already
patched. If an existing target differs from the repository copy, the helper
refuses to overwrite it. Review the difference and use `--replace` only when
the repository version is intentionally authoritative.

Every future source upgrade reruns the patch phase. Pin the known-good kernel
until the series has been checked and, if necessary, rebased for the new
release.

## 4. Applying to an existing source tree

If `/usr/src/linux` was prepared before the Portage files were installed,
either reprepare it through Portage or apply the files exactly once from the
kernel source root:

```bash
cd /usr/src/linux
git apply --check /path/to/repo/patches/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply /path/to/repo/patches/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply --check /path/to/repo/patches/0002-scsi-retry-quirked-media-change.patch
git apply /path/to/repo/patches/0002-scsi-retry-quirked-media-change.patch
git apply --check /path/to/repo/patches/0090-scsi-device-match.patch
git apply /path/to/repo/patches/0090-scsi-device-match.patch
```

`git apply` works even when the source itself is not a Git checkout. GNU patch
is also supported, but require an exact, zero-fuzz dry run first:

```bash
patch -p1 --fuzz=0 --dry-run < /path/to/0001-scsi-sd-handle-framework-microsd-resume.patch
patch -p1 --fuzz=0 < /path/to/0001-scsi-sd-handle-framework-microsd-resume.patch
patch -p1 --fuzz=0 --dry-run < /path/to/0002-scsi-retry-quirked-media-change.patch
patch -p1 --fuzz=0 < /path/to/0002-scsi-retry-quirked-media-change.patch
patch -p1 --fuzz=0 --dry-run < /path/to/0090-scsi-device-match.patch
patch -p1 --fuzz=0 < /path/to/0090-scsi-device-match.patch
```

Patch 2 depends on patch 1, and patch 3 opts in the configured reader. These
commands use the checked-in default identity. For another identity, first use
the installer with a staging `--destination` to render and review all three
files. If a check fails, stop. A reverse check can help identify an
already-applied series:

```bash
git apply --reverse --check /path/to/0090-scsi-device-match.patch
git apply --reverse --check /path/to/0002-scsi-retry-quirked-media-change.patch
```

Never force the series with fuzz, `--reject`, or hand-resolved context without
reviewing the current kernel semantics.

## 5. Configure the kernel

Select the intended source tree with `eselect kernel`, copy a trusted config,
and update it for the new release:

```bash
eselect kernel list
cd /usr/src/linux
cp /path/to/known-good-config .config
make olddefconfig
```

For the least fragile root-on-USB boot path, build these into the kernel:

```text
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_USB=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_XHCI_PCI=y
CONFIG_USB_STORAGE=y
CONFIG_XFS_FS=y
CONFIG_EFI_PARTITION=y
CONFIG_USB_DEFAULT_PERSIST=y
CONFIG_PM=y
CONFIG_PM_SLEEP=y
CONFIG_SUSPEND=y
CONFIG_DEVTMPFS=y
CONFIG_BLK_DEV_INITRD=y
```

[`config/root-on-usb.config`](../config/root-on-usb.config) is a reference
fragment, not a complete kernel configuration. If any root-path driver is a
module, it and all of its dependencies must be included in the matching
initramfs. Also enable the filesystem and partition parser actually used by
the system if they differ from XFS and GPT.

Verify the live config rather than assuming copied settings survived:

```bash
grep -E '^(CONFIG_(SCSI|BLK_DEV_SD|USB|USB_XHCI_HCD|USB_XHCI_PCI|USB_STORAGE|USB_DEFAULT_PERSIST|XFS_FS|EFI_PARTITION|PM|PM_SLEEP|SUSPEND|DEVTMPFS|BLK_DEV_INITRD))=' .config
```

## 6. Build under a unique release name

Use the same `LOCALVERSION` value for every command that calculates the kernel
release. The validated config already contributed `-fw12`, while the command
line contributed `-sdroot1`, producing
`6.18.33-gentoo-r1-fw12-sdroot1`.

```bash
cd /usr/src/linux
localversion=-sdroot1
release=$(make -s kernelrelease LOCALVERSION="$localversion")
printf 'Building %s\n' "$release"
make -j"$(nproc)" LOCALVERSION="$localversion"
sudo make LOCALVERSION="$localversion" modules_install
```

Rebuild any required out-of-tree modules for that exact release before
creating the initramfs. On Gentoo this often involves the `@module-rebuild`
set with `/usr/src/linux` selected, but follow the installed module packages'
own instructions. A dracut warning about a missing optional module is harmless
only if the machine truly does not need that subsystem for boot.

Then invoke the configured install helper with the same suffix:

```bash
sudo make LOCALVERSION="$localversion" install
```

On the validated host, `sys-kernel/installkernel` had `dracut`, `grub`, and
`systemd` integration enabled, so this installed the image, generated the
matching initramfs, and updated GRUB. Do not assume another Gentoo installation
has those USE flags or hooks. Inspect its installkernel configuration and run
the appropriate dracut and bootloader commands explicitly if needed.

Secure Boot installations must sign the new image and any enforced modules
with the locally enrolled key.

## 7. Verify before reboot

Confirm that the release name agrees everywhere and the fallback still
exists:

```bash
test -d "/lib/modules/$release"
find /boot -maxdepth 2 -type f -name "*$release*" -print
grep -F "$release" /boot/grub/grub.cfg
ls -lh /boot
```

If the root-path drivers are modular, inspect the initramfs with `lsinitrd` and
confirm the exact release's `scsi_mod`, `sd_mod`, xHCI, `usb-storage`, and XFS
modules are present. Correct any missing artifacts before rebooting.

The conservative kernel command line uses the configured USB ID:

```text
root=UUID=<root-filesystem-uuid> ro rootwait rootfstype=xfs \
usbcore.autosuspend=-1 usb-storage.quirks=<vid>:<pid>:u \
usbcore.quirks=<vid>:<pid>:k
```

Use the machine's real filesystem UUID; never copy one from another host.
The validated reader used `32ac:0026`. The USB quirk parameters cannot select
an `ID_PATH`, so they apply to every connected device with that VID:PID. The
`:u` flag disables UAS and belongs to the validated Bulk-Only setup; do not use
it for an intentionally UAS-based profile. Regenerate the bootloader
configuration after changing its defaults.

## 8. Boot and validate

Reboot into the new entry and confirm the exact release:

```bash
uname -r
cat /proc/cmdline
sudo ./scripts/collect-diagnostics.sh
```

The diagnostics use the installed profile rather than a hardcoded block,
SCSI, or USB topology name. The configured reader must contain all of these
live SCSI flags:

```text
INQUIRY_36 IGN_MEDIA_CHANGE SKIP_IO_HINTS RETRY_MEDIA_CHANGE
```

From a local console or a session that will survive suspend, with no unsaved
work and a verified backup, run:

```bash
sudo ./scripts/validate-resume.sh --check
sudo ./scripts/validate-resume.sh 20 15
```

The validator confirms that the matching reader backs the configured target,
that USB ID, optional physical `ID_PATH`, SCSI identity/revision, transport,
and live quirks match, and that a target write can be fsynced after every resume.
RTC wake deadlines can be preempted by other wake sources, so it reports early
wakes separately. Follow with actual lid-close tests and longer sleep periods;
direct `rtcwake` does not exercise desktop or lid-policy hooks.

For XFS, a post-install online read-only scrub is useful:

```bash
sudo xfs_scrub -n -k /
```

Do not remove the fallback kernel until the new release has survived normal
workloads, repeated lid-close resumes, and longer sleeps.

## 9. Kernel upgrades

For every upgrade:

1. Check whether an upstream equivalent now exists.
2. Render the configured series and check all three patches against a pristine
   new tree in order.
3. Inspect `include/scsi/scsi_devinfo.h` for use of bit 35.
4. Build a new, uniquely suffixed release without replacing the last working
   one.
5. Rebuild modules, initramfs, signatures, and bootloader entries together.
6. Repeat live-flag, root-write, suspend, lid, and journal validation.

See [troubleshooting](TROUBLESHOOTING.md) before attempting to resolve an apply
conflict, and [recovery](RECOVERY.md) before repairing a filesystem affected by
an older-kernel failure.
