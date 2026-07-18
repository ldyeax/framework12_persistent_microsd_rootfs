# Root-cause analysis

## Storage topology

The Framework MicroSD (2nd Gen) Expansion Card is not exposed to Linux through
the MMC subsystem. On the tested Framework Laptop 12, the path is:

```text
Intel Raptor Lake xHCI
  -> USB 32ac:0026
    -> usb-storage, Bulk-Only transport
      -> removable SCSI disk
        -> root partition
          -> XFS
```

Its SCSI inquiry strings are vendor `FRMW`, model `MicroSD(2nd Gen)`, and
tested revision `0001`. The device does not advertise UAS. This distinction is
important because MMC power flags and UAS error handling are not involved.

## Observed failure

The USB device normally remained enumerated across s2idle. After some resumes,
the reader reported a current-sense SCSI condition:

```text
Sense key: UNIT ATTENTION (0x06)
ASC/ASCQ:  0x28/0x00
Meaning:   not ready to ready change, medium may have changed
```

The condition was sometimes established approximately 0.54 seconds after the
kernel's suspend-exit message, rather than being present immediately in the
device resume callback.

For a removable SCSI disk, the normal Linux path treats `28/00` as evidence of
a real card change. `scsi_io_completion_action()` sets `sdev->changed` and
fails the command. Subsequent requests reach the SCSI disk setup path while
that flag is set and are rejected as an offline or changed device. The
two-second removable-media polling interval eventually clears the state, but
that is too late for a mounted root filesystem: writeback and metadata I/O can
already have failed, and XFS can force a shutdown.

The problem therefore looked like a lost root disk without an actual USB
disconnect.

## Evidence from retained journals

The investigation found:

| Signature | Count |
| --- | ---: |
| Exact `UNIT ATTENTION 28/00` events | 108 |
| Failed requests on the reader's SCSI disk | 305 |
| Failed writes | 228 |
| Failed reads | 77 |
| `device offline or changed` messages | 21,037 |
| XFS metadata I/O errors | 7 |
| Boots with XFS log recovery | 17 |

Of 236 recorded s2idle resumes, 66, or about 28%, produced the media-change
condition within two seconds. The affected windows did not show the USB reader
disconnecting, an xHCI command timeout, a UAS reset, or a bad-media sense-code
pattern. This made a physical card failure or ordinary USB re-enumeration a
poor fit for the repeatable resume correlation.

## Why the existing flags were insufficient

The tested command line already contained:

```text
rootwait rootfstype=xfs usbcore.autosuspend=-1 \
usb-storage.quirks=32ac:0026:u usbcore.quirks=32ac:0026:k
```

- `rootwait` waits for asynchronous root-device discovery during boot. It does
  not change post-resume SCSI error handling.
- `usbcore.autosuspend=-1` disables runtime USB autosuspend by default. System
  sleep uses a separate PM path.
- `usbcore.quirks=32ac:0026:k` disables USB link power management for this
  VID:PID. It does not reinterpret a SCSI Unit Attention.
- `usb-storage.quirks=32ac:0026:u` disables UAS. The reader was already using
  USB Bulk-Only transport, so this was redundant.

USB persistence is still important for a mounted filesystem. The successful
kernel used `CONFIG_USB_DEFAULT_PERSIST=y`, and the device should show
`power/persist=1`. Persistence cannot, however, prevent a device that remains
connected from returning SCSI `28/00`.

## Patch design

### Patch 1: eager sense clear

Linux already issued `REQUEST SENSE` on runtime resume for devices with
`BLIST_IGN_MEDIA_CHANGE`. Patch 1 factors that behavior into the common SCSI
disk resume path so a system resume can clear a condition before userspace and
normal I/O resume. It also introduces the exact `FRMW` / `MicroSD(2nd Gen)`
devinfo match.

This alone is insufficient when the reader establishes the Unit Attention
after the resume callback has already run.

### Patch 2: narrowly scoped completion retry

Patch 2 adds `BLIST_RETRY_MEDIA_CHANGE` and enables it only for the exact
reader identity. In normal command completion it retries only this tuple:

```text
current sense + UNIT_ATTENTION + ASC 0x28 + ASCQ 0x00
```

The failed command consumes the transient condition, and the retry proceeds
without setting `sdev->changed`. The same quirk prevents
`scsi_test_unit_ready()` from setting the changed flag for that normalized
tuple. Unlike the normal I/O call site, the TEST UNIT READY check does not
separately exclude a deferred-sense response. All other devices and all other
sense codes retain their existing behavior.

Patch 2 also limits the new system-resume sense clear to devices carrying the
new quirk. Existing devices with only `BLIST_IGN_MEDIA_CHANGE` retain their
previous runtime behavior.

The exact devinfo match includes `BLIST_SKIP_IO_HINTS`. In the tested SCSI scan
code, a devinfo match replaces the flags supplied by the lower-level USB
storage driver. Retaining this flag avoids accidentally re-enabling an IO
Advice Hints Grouping mode-page query that USB storage intentionally skips.

## Deliberate tradeoff

The workaround treats `28/00` as spurious for every reader matching the exact
SCSI identity. A genuine removal or replacement reported only through that
sense tuple will not receive normal removable-media handling. That tradeoff is
necessary for a mounted root device but makes the operational rule absolute:
never remove or replace the card while the system is running or suspended.

This is not a general solution for USB disconnects, controller resets,
timeouts, bad flash media, or other Unit Attention codes.

## Validation result

The installed kernel was `6.18.33-gentoo-r1-fw12-sdroot1`. On 2026-07-18 it
completed 20 s2idle transitions with a successful fsynced root write following
each resume. The same boot showed 20 suspend entries and exits and no matching
Unit Attention, block I/O, changed-device, or XFS errors. Six RTC cycles met
the requested approximately 15-second sleep; 14 woke early from another wake
source but still exercised the suspend/resume path.

An online read-only `xfs_scrub -n -k /` also completed without corruption or a
repair requirement. Its remaining reports were optional layout optimizations
and filename-confusability notices.

Unrelated `spd5118` and UCSI resume warnings occurred on this host. They did
not correlate with the microSD signatures and are outside this workaround.

## References

- [USB device persistence](https://docs.kernel.org/driver-api/usb/persist.html)
- [USB power management](https://docs.kernel.org/driver-api/usb/power-management.html)
- [Linux kernel parameters](https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html)
- [Related SCSI REQUEST SENSE discussion](https://lkml.iu.edu/2106.3/05387.html)
- [T10 clarification 06-264r2](https://www.t10.org/ftp/t10/document.06/06-264r2.pdf)
