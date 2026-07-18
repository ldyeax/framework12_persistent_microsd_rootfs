# Recovery and rollback

## If resume loses the root filesystem

Minimize further writes. A forced XFS shutdown cannot be made healthy by
continuing to use the mounted instance. If the system still responds, capture
the current kernel journal to persistent storage only if that can be done
without depending on the failed root path, then reboot through the safest
available mechanism.

At GRUB, select the known-good fallback kernel. Because an unpatched fallback
remains vulnerable to the resume failure, do not suspend it; use it only for
diagnosis, rebuilding, or booting into a controlled recovery.

If no installed kernel boots reliably, use rescue media.

## Inspect XFS from rescue media

Identify the correct partition by UUID and topology. Do not assume it is
`/dev/sda3`; enumeration can change in a rescue environment.

```bash
lsblk -f
blkid
findmnt --verify 2>/dev/null || true
```

Keep the target unmounted. If it was automatically mounted, unmount it before
repair work. Back up irreplaceable data or image the card first when possible.

Run a no-modify assessment:

```bash
sudo xfs_repair -n /dev/<root-partition>
```

Review the complete result. Run modifying `xfs_repair` only on the unmounted
filesystem, only when the assessment and recovery plan justify it:

```bash
sudo xfs_repair /dev/<root-partition>
```

`fsck.xfs` does not repair XFS. Do not run `xfs_repair` against a mounted root,
and do not use log-destroying options casually. Consult current xfsprogs
documentation when the tool requests an exceptional option.

After a clean boot, a read-only online scrub can provide additional coverage:

```bash
sudo xfs_scrub -n -k /
```

## Repair the kernel installation from a fallback

Confirm which release is running and which source tree is selected:

```bash
uname -r
eselect kernel list 2>/dev/null || true
find /boot -maxdepth 2 -type f -print
find /lib/modules -mindepth 1 -maxdepth 1 -type d -print
```

Reapply or rebuild from the documented procedure. Keep the release suffix
consistent through build, modules installation, initramfs generation, and
image installation. Verify the bootloader entry before rebooting.

## Roll back the out-of-tree workaround

Removing the workaround restores the original suspend risk. Boot a different
kernel first and avoid suspend while rolling back.

For Gentoo, remove the two files from
`/etc/portage/patches/sys-kernel/gentoo-sources/` only after recording why the
rollback is being done. Prepare a fresh source tree rather than trying to build
a partially reversed one. If reversal is necessary for review, reverse patch
2 before patch 1:

```bash
git apply --reverse --check patches/0002-scsi-retry-quirked-media-change.patch
git apply --reverse patches/0002-scsi-retry-quirked-media-change.patch
git apply --reverse --check patches/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply --reverse patches/0001-scsi-sd-handle-framework-microsd-resume.patch
```

Build the rollback under another unique release name. Do not delete the last
working patched kernel until its replacement has been validated, and do not
delete rescue media or backups as part of routine cleanup.
