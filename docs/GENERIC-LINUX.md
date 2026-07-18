# Generic Linux installation

The live fix was validated on Gentoo, but the code changes are in the Linux
SCSI core and can be built by other distributions. This page describes the
requirements without assuming a particular package manager or bootloader.

Only the Framework Laptop 12 Intel x86_64 system with the exact reader identity
has runtime validation. Treat every other kernel, architecture, initramfs
generator, and boot stack as a new port that needs full testing.

## Preserve a recovery path

Before building:

- back up the root card;
- prepare bootable rescue media with XFS tools if the root is XFS;
- retain a known-good kernel, initramfs, module tree, and boot entry;
- verify `/boot` and the EFI System Partition are mounted and have free space;
- avoid suspend or lid close while running a vulnerable kernel.

Use a unique local version so the experimental image cannot overwrite the
fallback.

## Verify the target

The static quirk matches only SCSI vendor `FRMW` and model
`MicroSD(2nd Gen)`. The validated USB ID is `32ac:0026`, using
`usb-storage` Bulk-Only transport.

```bash
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /
lsusb -d 32ac:0026
lsusb -t
./scripts/collect-diagnostics.sh
```

Confirm through `lsblk -s` or sysfs that this reader is actually an ancestor of
the root partition. A different product, first-generation reader, UAS device,
or MMC device is outside the patch's match and evidence.

## Obtain a reviewable kernel source

Start with the distribution's complete source and patch set or an official
kernel.org tree. Record its exact version and configuration. The series was
runtime-tested at `6.18.33-gentoo-r1` and clean-apply-tested against upstream
6.18.0 and upstream-equivalent 6.18.33 SCSI sources. It is not guaranteed for
other releases.

Before applying, inspect the new source for:

- an existing `FRMW` / `MicroSD(2nd Gen)` entry;
- an upstream fix with equivalent semantics;
- use of bit 35 by another `BLIST_*` flag;
- changes around `sd_resume_common()`, `scsi_io_completion_action()`, or
  `scsi_test_unit_ready()`.

Stop and rebase deliberately if any of these differ. Never force rejected or
fuzzy hunks.

## Apply and inspect the series

From the source root:

```bash
(cd /path/to/repo/patches && sha256sum -c SHA256SUMS)
git apply --check /path/to/repo/patches/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply /path/to/repo/patches/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply --check /path/to/repo/patches/0002-scsi-retry-quirked-media-change.patch
git apply /path/to/repo/patches/0002-scsi-retry-quirked-media-change.patch
```

`git apply` works outside a Git checkout. With GNU patch, use
`patch -p1 --fuzz=0 --dry-run` and then `patch -p1 --fuzz=0` for each file in
the same order. Patch 2 depends on patch 1.

If the kernel ships `scripts/checkpatch.pl`, the publication checks are:

```bash
scripts/checkpatch.pl --no-tree --strict --no-signoff /path/to/repo/patches/0001-*.patch
scripts/checkpatch.pl --no-tree --strict --no-signoff /path/to/repo/patches/0002-*.patch
```

## Configure the root and sleep paths

Prefer built-in drivers for a root filesystem on USB:

```text
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_USB=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_XHCI_PCI=y
CONFIG_USB_STORAGE=y
CONFIG_XFS_FS=y                 # or the actual root filesystem
CONFIG_EFI_PARTITION=y         # or the actual partition parser
CONFIG_USB_DEFAULT_PERSIST=y
CONFIG_PM=y
CONFIG_PM_SLEEP=y
CONFIG_SUSPEND=y
CONFIG_DEVTMPFS=y
```

If any required storage or filesystem driver is modular, enable
`CONFIG_BLK_DEV_INITRD=y` and guarantee the exact modules and dependencies are
present in the matching initramfs. Typical modules include `scsi_mod`,
`sd_mod`, `xhci-hcd`, `xhci-pci`, `usb-storage`, and `xfs`. A root-on-USB
initramfs must also wait for asynchronous USB enumeration.

Use `make olddefconfig` or the distribution's supported config update, then
verify the resulting `.config`; a fragment by itself does not change a build.

## Build with a unique release

The same local-version argument must reach every make invocation that derives
the release name:

```bash
localversion=-fw12-sdroot1
make olddefconfig
release=$(make -s kernelrelease LOCALVERSION="$localversion")
make -j"$(nproc)" LOCALVERSION="$localversion"
sudo make LOCALVERSION="$localversion" modules_install
sudo depmod "$release"
```

Rebuild required out-of-tree modules for `$release` before generating the
initramfs. Verify module vermagic and signing requirements. If Secure Boot is
enforced, sign the image and modules with an enrolled key.

## Install according to the distribution

`make install` is not portable policy. A distribution's install helper may or
may not copy the image, generate an initramfs, sign it, and update the
bootloader. Follow its documented mechanism. Common initramfs tools include
dracut, mkinitcpio, and update-initramfs, but their configuration and filenames
differ.

Before rebooting, verify all of the following for the exact `$release`:

- kernel image, `System.map`, and config where the distribution expects them;
- `/lib/modules/$release` and correct module vermagic;
- initramfs containing every modular root-path driver;
- a bootloader entry pointing to the new image and initramfs;
- the previous bootable entry still present;
- sufficient space and correct mounts for `/boot` and the ESP.

A conservative initial command line is:

```text
root=UUID=<actual-root-uuid> ro rootwait rootfstype=<actual-filesystem> \
usbcore.autosuspend=-1 usb-storage.quirks=32ac:0026:u \
usbcore.quirks=32ac:0026:k
```

The SCSI patches fix the observed Unit Attention failure. The USB power flags
do not. They are retained to reproduce the tested configuration and can be
evaluated one at a time after reliability is established. The `u` quirk is
redundant when the reader is already on Bulk-Only transport.

## Validate the running kernel

After boot, confirm the new release, root source, transport, and current-boot
journal. Dynamically locate the SCSI reader and require this complete live flag
set:

```text
INQUIRY_36 IGN_MEDIA_CHANGE SKIP_IO_HINTS RETRY_MEDIA_CHANGE
```

On systems with a readable systemd kernel journal and util-linux, use:

```bash
sudo ./scripts/validate-resume.sh --check
sudo ./scripts/validate-resume.sh 20 15
```

The test checks that the reader backs `/`, writes and fsyncs `/` after each
resume, and fails on the known block and filesystem signatures. It reports
early wakes because an RTC deadline does not prevent another wake source. It
does not test desktop or lid hooks; repeat the test with actual lid close and
longer real-world sleeps.

On a non-journald system, reproduce the same procedure manually while
capturing the kernel ring buffer persistently. Do not treat a logging failure
as a successful storage test.

Never remove or replace the root card while the system is running or
suspended.
