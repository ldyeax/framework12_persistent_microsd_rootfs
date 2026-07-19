# Device and slot configuration

The checked-in profile in [`config/device.conf`](../config/device.conf) records
the hardware used for the validated result. The installer, diagnostics helper,
and resume validator all use the same profile loader. None of them assumes a
`/dev/sdX` name, SCSI `H:C:T:L` address, or transient USB sysfs node such as
`2-4`.

Run this before installing to see the resolved values:

```bash
./scripts/install-gentoo-patches.sh --show-config
```

## What each selector controls

| Config key | Command-line option | Environment variable | Repository default | Purpose |
| --- | --- | --- | --- | --- |
| `usb_id` | `--usb-id VID:PID` | `SDROOT_USB_ID` | `32ac:0026` | USB vendor and product runtime guard; also supplies the ID used in the recommended boot parameters |
| `usb_path` | `--usb-path ID_PATH` or `--usb-slot ID_PATH` | `SDROOT_USB_PATH` | `any` | Optional physical expansion-bay guard using udev `ID_PATH` |
| `scsi_vendor` | `--scsi-vendor VENDOR` | `SDROOT_SCSI_VENDOR` | `FRMW` | Exact SCSI inquiry vendor used by the kernel quirk |
| `scsi_model` | `--scsi-model MODEL` | `SDROOT_SCSI_MODEL` | `MicroSD(2nd Gen)` | SCSI inquiry model prefix used by the kernel quirk |
| `scsi_revision` | `--scsi-revision REV` | `SDROOT_SCSI_REVISION` | `any` | Runtime guard only; use `any` or a 1-4 character revision |
| `transport` | `--transport DRIVER` | `SDROOT_TRANSPORT` | `usb-storage` | Runtime USB interface-driver guard |
| `target` | `--target MOUNTPOINT` | `SDROOT_TARGET` | `/` | Mounted filesystem whose backing device and post-resume writes are validated |
| `rtc_device` | `--rtc-device /dev/rtcN` | `SDROOT_RTC_DEVICE` | `/dev/rtc0` | RTC used to wake the suspend test |
| `allow_model_prefix` | `--allow-model-prefix` or `--no-allow-model-prefix` | `SDROOT_ALLOW_MODEL_PREFIX` | `no` | Explicit opt-in for a SCSI model shorter than 16 characters |

The SCSI device table can select by vendor and model only. USB ID, physical
path, SCSI revision, transport, target mount, and RTC constrain runtime checks;
they do not narrow which devices receive the compiled kernel quirk. A custom
profile therefore must not be described as a per-bay or per-USB-device kernel
match.

The static SCSI table requires an exact vendor match but treats its model as a
prefix. A 16-character model consumes the full inquiry model field. The
installer rejects shorter custom models unless `allow_model_prefix=yes` or
`--allow-model-prefix` explicitly acknowledges that the match can cover more
models.

## Selecting the physical expansion bay

Linux USB node names such as `2-4`, block names such as `sda`, and SCSI
addresses such as `0:0:0:0` can change across boots. `usb_path` instead accepts
udev's stable topology property, `ID_PATH`. The tested reader currently reports:

```text
pci-0000:00:0d.0-usb-0:4
```

Discover the value for the reader in its intended bay with:

```bash
sudo ./scripts/collect-diagnostics.sh
```

The `Configured USB reader candidates` section prints each matching USB ID and
its `ID_PATH`. Set the selected value in a profile or pass it directly:

```bash
sudo ./scripts/validate-resume.sh \
    --usb-slot pci-0000:00:0d.0-usb-0:4 --check
```

Resolving and enforcing an `ID_PATH` requires `udevadm`; the validator treats
it as a required dependency whenever `usb_path` is not `any`.

Move the reader between bays and repeat discovery rather than guessing the
path. Firmware or topology changes can alter `ID_PATH`; in that case the
validator fails closed until the profile is reviewed. Use `usb_path=any` only
when accepting any physical bay with the configured USB identity is intended.

`--portage-slot` is unrelated. It selects a Gentoo package SLOT directory such
as `gentoo-sources:6.18.33-r1`; it does not select a Framework expansion bay.

## Config files and precedence

The helpers resolve settings in this order, from highest to lowest priority:

1. Device options on the command line.
2. `SDROOT_*` environment variables.
3. The selected config file.
4. Built-in tested defaults, which are also recorded in `config/device.conf`.

The config file is selected by `--config FILE`, then `SDROOT_CONFIG`, then
`/etc/framework-microsd-rootfs.conf` if it exists, and finally the checked-in
`config/device.conf`.

Files use one unquoted `key=value` assignment per line. Empty lines and lines
whose first non-space character is `#` are ignored. Inline comments and shell
syntax are not supported. The parser does not use `source` or `eval`; it
rejects malformed lines, duplicate keys, unknown keys, unsafe inquiry strings,
and invalid device formats.

The default Gentoo install writes the resolved profile to
`/etc/framework-microsd-rootfs.conf` so later diagnostics and validation use
the same selectors as the rendered device-match patch. Use
`--config-destination FILE` to choose another path or `--no-config-install` to
stage patches without persisting a system profile.

## Default and custom installation

For the tested device in any bay:

```bash
sudo ./scripts/install-gentoo-patches.sh
```

For the tested device constrained to the tested physical bay:

```bash
sudo ./scripts/install-gentoo-patches.sh \
    --usb-slot pci-0000:00:0d.0-usb-0:4
```

For a slot-qualified Gentoo sources package, keep the two slot concepts
separate:

```bash
sudo ./scripts/install-gentoo-patches.sh \
    --usb-slot pci-0000:00:0d.0-usb-0:4 \
    --portage-slot 6.18.33-r1
```

For different hardware, first establish that it has the same failure and
review its complete SCSI inquiry strings. Then create a reviewed config and
render a series from it:

```bash
./scripts/install-gentoo-patches.sh \
    --config /path/to/reviewed-device.conf \
    --destination /tmp/rendered-sdroot-patches \
    --no-config-install
```

The first two output patches contain device-neutral SCSI behavior. The third
is rendered from `0090-scsi-device-match.patch.in` with the configured SCSI
vendor and model. A nondefault identity produces an explicit warning and has
not inherited the Framework reader's runtime evidence. Inspect and test the
rendered series before installing it.

## Boot parameters

The installer does not rewrite a bootloader configuration. For the tested
Bulk-Only (`usb-storage`) setup, substitute the configured `usb_id` when
reproducing the conservative command line:

```text
rootwait rootfstype=<actual-filesystem> usbcore.autosuspend=-1 \
usb-storage.quirks=<vid>:<pid>:u usbcore.quirks=<vid>:<pid>:k
```

These USB flags cannot be scoped by `ID_PATH`. They cover every attached USB
device with that VID:PID. They also do not replace the SCSI patch series. The
`:u` flag disables UAS, so do not copy it for a profile intentionally using
`transport=uas`; that transport remains outside this repository's runtime
validation evidence.
