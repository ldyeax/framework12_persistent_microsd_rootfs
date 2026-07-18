#!/bin/bash
# SPDX-License-Identifier: MIT
set -u

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

section "Root filesystem"
if command -v findmnt >/dev/null; then
	findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /
	root_source=$(findmnt -n -o SOURCE /)
	if command -v lsblk >/dev/null; then
		lsblk -s -o NAME,KNAME,TYPE,FSTYPE,MOUNTPOINTS "$root_source" 2>&1 || true
	fi
fi

section "Kernel command line and sleep state"
if [[ -r /proc/cmdline ]]; then
	printf '/proc/cmdline: '
	sed -E \
		-e 's/(root=UUID=)[^ ]+/\1<redacted>/g' \
		-e 's/(resume=UUID=)[^ ]+/\1<redacted>/g' \
		/proc/cmdline
fi
read_file /sys/power/state
read_file /sys/power/mem_sleep

section "Framework USB reader"
if command -v lsusb >/dev/null; then
	lsusb -d 32ac:0026 2>&1 || true
	lsusb -t 2>&1 || true
else
	echo "lsusb is not installed."
fi

for usb in /sys/bus/usb/devices/*; do
	[[ -r $usb/idVendor && -r $usb/idProduct ]] || continue
	[[ $(<"$usb/idVendor") == 32ac && $(<"$usb/idProduct") == 0026 ]] || continue

	printf '\nUSB sysfs node: %s\n' "${usb##*/}"
	for attribute in product bcdDevice speed power/control power/runtime_status power/persist; do
		read_file "$usb/$attribute"
	done
	if [[ -L $usb/driver ]]; then
		printf 'driver: %s\n' "$(basename -- "$(readlink -f -- "$usb/driver")")"
	fi
done

section "SCSI devices"
for device in /sys/class/scsi_device/*/device; do
	[[ -r $device/vendor && -r $device/model ]] || continue
	vendor=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' < "$device/vendor")
	model=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' < "$device/model")
	[[ $vendor == FRMW || $model == *MicroSD* ]] || continue

	printf '\nSCSI sysfs node: %s\n' "${device%/device}"
	for attribute in vendor model rev type state removable blacklist; do
		read_file "$device/$attribute"
	done
	for block_path in "$device"/block/*; do
		[[ -e $block_path ]] && printf 'block device: %s\n' "${block_path##*/}"
	done
done

section "Relevant current-boot kernel messages"
pattern='32ac:0026|MicroSD|Unit Attention|medium may have changed|device offline or changed|rejecting I/O to offline device|I/O error|writeback error|XFS.*(error|shutdown)|PM: suspend (entry|exit)'
if command -v journalctl >/dev/null; then
	journalctl -b -k --no-pager -o short-monotonic 2>&1 |
		grep -Ei "$pattern" |
		tail -n 300 |
		sed -E \
			-e 's/(root=UUID=)[^ ]+/\1<redacted>/g' \
			-e 's/(resume=UUID=)[^ ]+/\1<redacted>/g' \
			-e 's/^(\[[^]]+\])[[:space:]]+[^[:space:]]+[[:space:]]+kernel:/\1 kernel:/' || true
else
	dmesg 2>&1 |
		grep -Ei "$pattern" |
		tail -n 300 |
		sed -E \
			-e 's/(root=UUID=)[^ ]+/\1<redacted>/g' \
			-e 's/(resume=UUID=)[^ ]+/\1<redacted>/g' || true
fi

echo
echo "Hostname, root/resume UUIDs, and storage serial numbers are intentionally omitted."
