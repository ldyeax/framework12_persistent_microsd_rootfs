# Kernel patch series

Apply these files in lexical order:

1. `0001-scsi-sd-handle-framework-microsd-resume.patch`
2. `0002-scsi-retry-quirked-media-change.patch`
3. `0090-scsi-device-match.patch`

Patch 2 is incremental and requires patch 1. Patch 3 opts a device into the
behavior introduced by both earlier patches. The files have neutral mbox
delimiters but intentionally omit author metadata, so use `git apply` or
`patch -p1`, not `git am`.

The checked-in `0090` patch is the tested default rendered from
`0090-scsi-device-match.patch.in`. Portage ignores the `.patch.in` template.
The installer copies the two device-neutral patches and renders a new `0090`
for the configured SCSI inquiry identity. See
[`docs/CONFIGURATION.md`](../docs/CONFIGURATION.md) before generating a match
for another device.

## Tested applicability

The default series was built and runtime-validated on Linux
`6.18.33-gentoo-r1` with a unique local version. It has also been checked
against clean upstream-equivalent 6.18.33 SCSI sources and clean upstream Linux
6.18.0. All three default patches pass the kernel's
`scripts/checkpatch.pl --no-tree --strict --no-signoff` with no findings.

This is not a promise of compatibility with other releases. Before every
kernel upgrade, check and apply all three files in order:

```bash
git apply --check /path/to/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply /path/to/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply --check /path/to/0002-scsi-retry-quirked-media-change.patch
git apply /path/to/0002-scsi-retry-quirked-media-change.patch
git apply --check /path/to/0090-scsi-device-match.patch
git apply /path/to/0090-scsi-device-match.patch
```

Run those commands from the kernel source root. `git apply` does not require
the source tree itself to be a Git checkout. For a non-Git workflow, dry-run
and apply each patch with `patch -p1 --fuzz=0 --dry-run` followed by
`patch -p1 --fuzz=0`.

Do not force a failed patch with fuzz or reject files. Check whether the new
kernel already contains an equivalent fix, has changed the affected SCSI
paths, or has assigned bit 35 to another `BLIST_*` flag. Patch 2 defines
`BLIST_RETRY_MEDIA_CHANGE` at bit 35 and advances `__BLIST_LAST_USED`.

`drivers/scsi/scsi_devinfo_tbl.c` is generated during the kernel build. It is
intentionally absent from this series; the new flag-name row is generated from
`include/scsi/scsi_devinfo.h`.

The device entry must retain `BLIST_SKIP_IO_HINTS`. In this kernel, an exact
SCSI devinfo match replaces transport-provided flags rather than merely adding
to them. Omitting it could re-enable the IO Advice Hints Grouping mode-page
query that USB storage already avoids.

## Match scope and semantics

The default table entry matches exact SCSI vendor `FRMW` and model prefix
`MicroSD(2nd Gen)` across all revisions. That model occupies all 16 inquiry
model characters, so it is effectively exact for the field. A shorter custom
model is a broader prefix and requires explicit installer acknowledgement.

Linux's static SCSI devinfo table cannot match a USB VID:PID, physical USB
path, SCSI revision, block name, or SCSI address. Those profile fields are
runtime guards only. The kernel quirk applies to every device matching the
configured SCSI vendor/model, independent of which Framework expansion bay it
occupies.

Normal I/O completion retries only current-sense `UNIT_ATTENTION` with
ASC/ASCQ `28/00`. TEST UNIT READY polling suppresses the changed flag for the
same normalized tuple without separately rejecting a deferred-sense response.
The matching reader must be treated as fixed media: never remove or replace
its card while the machine is running or suspended.

The repository patches intentionally contain no author or `Signed-off-by`
trailer. A human preparing an upstream submission should create a proper
commit and add a sign-off only after reviewing the changes and affirming the
Developer Certificate of Origin.

## Integrity

Verify the static patches and template from this directory:

```bash
sha256sum -c SHA256SUMS
```

The installer also prints checksums for its resolved, rendered series. Kernel
patches are licensed GPL-2.0-only because they contain modifications to Linux
kernel code.
