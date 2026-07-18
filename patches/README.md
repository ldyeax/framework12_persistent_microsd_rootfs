# Kernel patch series

Apply these files in lexical order:

1. `0001-scsi-sd-handle-framework-microsd-resume.patch`
2. `0002-scsi-retry-quirked-media-change.patch`

Patch 2 is incremental and will not apply to a pristine tree before patch 1.
The files have neutral mbox delimiters but intentionally omit author metadata,
so use `git apply` or `patch -p1`, not `git am`. Their rationale and safety
constraints are documented here and in the repository's root-cause analysis.

## Tested applicability

The runtime result was built and validated on Linux
`6.18.33-gentoo-r1` with a unique local version. The corrected series has also
been checked against clean upstream-equivalent 6.18.33 SCSI sources and clean
upstream Linux 6.18.0. Both patches pass the kernel's
`scripts/checkpatch.pl --no-tree --strict --no-signoff` with no findings.

This is not a promise of compatibility with other releases. Before every
kernel upgrade:

```bash
git apply --check /path/to/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply /path/to/0001-scsi-sd-handle-framework-microsd-resume.patch
git apply --check /path/to/0002-scsi-retry-quirked-media-change.patch
git apply /path/to/0002-scsi-retry-quirked-media-change.patch
```

Run those commands from the kernel source root. `git apply` does not require
the source tree itself to be a Git checkout. For a non-Git workflow, dry-run
and apply each patch with `patch -p1 --dry-run` followed by `patch -p1`.

Do not force a failed patch with fuzz or reject files. Check whether the new
kernel already contains an equivalent fix, has changed the affected SCSI
paths, or has assigned bit 35 to another `BLIST_*` flag. Patch 2 defines
`BLIST_RETRY_MEDIA_CHANGE` at bit 35 and advances `__BLIST_LAST_USED`.

`drivers/scsi/scsi_devinfo_tbl.c` is generated during the kernel build. It is
intentionally absent from this series; the new flag-name row is generated from
`include/scsi/scsi_devinfo.h`.

The exact Framework entry must retain `BLIST_SKIP_IO_HINTS`. In this kernel,
the SCSI devinfo lookup replaces transport-provided flags rather than merely
adding to them. Omitting it could re-enable the IO Advice Hints Grouping mode
page query that USB storage already avoids.

## Device semantics

The table entry matches SCSI vendor `FRMW` and model `MicroSD(2nd Gen)` across
all revisions. Normal I/O completion retries only current-sense
`UNIT_ATTENTION` with ASC/ASCQ `28/00`. TEST UNIT READY polling suppresses the
changed flag for the same normalized tuple without separately rejecting a
deferred-sense response. The matching reader must be treated as fixed media:
never remove or replace its card while the machine is running or suspended.

The repository patches intentionally contain no author or `Signed-off-by`
trailer. A human preparing an upstream submission should create a proper
commit and add a sign-off only after reviewing the changes and affirming the
Developer Certificate of Origin.

## Integrity

Verify the distributed files from this directory:

```bash
sha256sum -c SHA256SUMS
```

The patches are licensed GPL-2.0-only because they contain modifications to
Linux kernel code.
