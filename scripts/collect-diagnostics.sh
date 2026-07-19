#!/bin/bash
# SPDX-License-Identifier: MIT
set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
# shellcheck source=lib/device-config.sh
source "$script_dir/lib/device-config.sh"

usage() {
	cat <<'EOF'
Usage: collect-diagnostics.sh [options]

Target profile (CLI overrides environment and --config):
  --config FILE
  --usb-id VID:PID
  --usb-path ID_PATH         Constrain a physical slot by udev ID_PATH
  --usb-slot ID_PATH         Alias for --usb-path
  --scsi-vendor VENDOR
  --scsi-model MODEL
  --scsi-revision REV|any
  --transport DRIVER
  --target MOUNTPOINT
  --rtc-device /dev/rtcN
  --allow-model-prefix
  --no-allow-model-prefix
  --show-config              Print only the resolved profile
EOF
}

section() {
	printf '\n== %s ==\n' "$1"
}

read_file() {
	local path=$1
	if [[ -r $path ]]; then
		printf '%s: ' "$path"
		cat -- "$path"
	fi
}

sanitize_stream() {
	sed -E \
		-e 's/(root=UUID=)[^ ]+/\1<redacted>/g' \
		-e 's/(resume=UUID=)[^ ]+/\1<redacted>/g' \
		-e 's#(/dev/disk/by-(part)?uuid/)[^ ]+#\1<redacted>#g' \
		-e 's/^(\[[^]]+\])[[:space:]]+[^[:space:]]+[[:space:]]+kernel:/\1 kernel:/'
}

show_config=false
for argument in "$@"; do
	case $argument in
	-h | --help)
		usage
		exit 0
		;;
	esac
done

sdroot_config_prepare "$repo_root" "$@" || exit $?

while (($#)); do
	case $1 in
	--show-config) show_config=true; shift ;;
	--config)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		shift 2
		;;
	--config=*) shift ;;
	--usb-id)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_USB_ID=$2; shift 2
		;;
	--usb-path | --usb-slot)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_USB_PATH=$2; shift 2
		;;
	--scsi-vendor)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_SCSI_VENDOR=$2; shift 2
		;;
	--scsi-model)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_SCSI_MODEL=$2; shift 2
		;;
	--scsi-revision)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_SCSI_REVISION=$2; shift 2
		;;
	--transport)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_TRANSPORT=$2; shift 2
		;;
	--target)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_TARGET=$2; shift 2
		;;
	--rtc-device)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_RTC_DEVICE=$2; shift 2
		;;
	--allow-model-prefix) SDROOT_CFG_ALLOW_MODEL_PREFIX=yes; shift ;;
	--no-allow-model-prefix) SDROOT_CFG_ALLOW_MODEL_PREFIX=no; shift ;;
	-h | --help) usage; exit 0 ;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

sdroot_config_validate || exit $?
if [[ $show_config == true ]]; then
	sdroot_config_print
	exit 0
fi

section "Resolved target profile"
sdroot_config_print

section "Kernel and platform"
uname -srmo
for path in \
	/sys/class/dmi/id/sys_vendor \
	/sys/class/dmi/id/product_name \
	/sys/class/dmi/id/product_version \
	/sys/class/dmi/id/bios_version \
	/sys/class/dmi/id/bios_date; do
	read_file "$path"
done

section "Target filesystem"
if command -v findmnt >/dev/null; then
	findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS -M "$SDROOT_CFG_TARGET" 2>&1 |
		sanitize_stream || true
	target_source=$(findmnt -n -o SOURCE -M "$SDROOT_CFG_TARGET" 2>/dev/null || true)
	if [[ -n $target_source ]] && command -v lsblk >/dev/null; then
		lsblk -s -o NAME,KNAME,TYPE,FSTYPE,MOUNTPOINTS "$target_source" 2>&1 |
			sanitize_stream || true
	fi
fi

section "Kernel command line and sleep state"
if [[ -r /proc/cmdline ]]; then
	printf '/proc/cmdline: '
	sanitize_stream < /proc/cmdline
fi
read_file /sys/power/state
read_file /sys/power/mem_sleep

section "Configured USB reader candidates"
if command -v lsusb >/dev/null; then
	lsusb -d "$SDROOT_CFG_USB_ID" 2>&1 || true
	lsusb -t 2>&1 || true
else
	echo "lsusb is not installed."
fi

for usb in /sys/bus/usb/devices/*; do
	sdroot_usb_id_matches "$usb" || continue
	id_path=unavailable
	if sdroot_usb_id_path "$usb"; then
		id_path=$REPLY
	fi
	path_match=no
	[[ $SDROOT_CFG_USB_PATH == any || $id_path == "$SDROOT_CFG_USB_PATH" ]] && path_match=yes

	printf '\nUSB sysfs node: %s\n' "${usb##*/}"
	printf 'ID_PATH: %s\nconfigured path match: %s\n' "$id_path" "$path_match"
	for attribute in product bcdDevice speed power/control power/runtime_status power/persist; do
		read_file "$usb/$attribute"
	done
	if [[ -L $usb/driver ]]; then
		printf 'device-core driver: %s\n' "$(basename -- "$(readlink -f -- "$usb/driver")")"
	fi
	for interface in "$usb"/*:*; do
		[[ -L $interface/driver ]] || continue
		printf 'interface %s driver: %s\n' "${interface##*/}" \
			"$(basename -- "$(readlink -f -- "$interface/driver")")"
	done
done

section "SCSI disk candidates"
for device in /sys/class/scsi_device/*/device; do
	[[ -r $device/vendor && -r $device/model && -r $device/rev ]] || continue
	[[ ! -r $device/type || $(<"$device/type") == 0 ]] || continue
	sdroot_read_scsi_identity "$device"
	configured_match=no
	if sdroot_scsi_matches "$device"; then
		configured_match=yes
	fi

	printf '\nSCSI sysfs node: %s\n' "${device%/device}"
	printf 'identity: %s / %s / %s\nconfigured identity match: %s\n' \
		"$SDROOT_FOUND_SCSI_VENDOR" "$SDROOT_FOUND_SCSI_MODEL" \
		"$SDROOT_FOUND_SCSI_REVISION" "$configured_match"
	for attribute in type state blacklist; do
		read_file "$device/$attribute"
	done
	for block_path in "$device"/block/*; do
		[[ -e $block_path ]] || continue
		printf 'block device: %s\n' "${block_path##*/}"
		read_file "$block_path/removable"
	done
done

section "Relevant current-boot kernel messages"
sdroot_ere_escape "$SDROOT_CFG_USB_ID"
usb_pattern=$REPLY
sdroot_ere_escape "$SDROOT_CFG_SCSI_MODEL"
model_pattern=$REPLY
pattern="$usb_pattern|$model_pattern|Unit Attention|medium may have changed|device offline or changed|rejecting I/O to offline device|I/O error|writeback error|XFS.*(error|shutdown)|PM: suspend (entry|exit)"
if command -v journalctl >/dev/null; then
	journalctl -b -k --no-pager -o short-monotonic 2>&1 |
		grep -Ei "$pattern" |
		tail -n 300 |
		sanitize_stream || true
else
	dmesg 2>&1 |
		grep -Ei "$pattern" |
		tail -n 300 |
		sanitize_stream || true
fi

echo
echo "Hostname, root/resume UUIDs, and storage serial numbers are intentionally omitted."
