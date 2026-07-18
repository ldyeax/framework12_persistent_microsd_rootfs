#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: validate-resume.sh [cycles] [suspend-seconds]
       validate-resume.sh --check

Run guarded suspend/resume cycles against a patched Framework MicroSD root.
--check performs every preflight and root write but does not suspend.
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

check_only=false
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
	usage
	exit 0
elif [[ ${1:-} == --check ]]; then
	[[ $# -eq 1 ]] || {
		usage >&2
		exit 2
	}
	check_only=true
	cycles=0
	seconds=0
else
	cycles=${1:-20}
	seconds=${2:-15}
	[[ $# -le 2 && $cycles =~ ^[1-9][0-9]*$ && $seconds =~ ^[1-9][0-9]*$ ]] || {
		usage >&2
		exit 2
	}
fi

[[ $EUID -eq 0 ]] || die "Run as root."

required=(awk date findmnt flock grep journalctl lsblk mktemp readlink rm rtcwake sed sleep sync tail tr uname)
for command_name in "${required[@]}"; do
	command -v "$command_name" >/dev/null || die "Required command not found: $command_name"
done

[[ -r /sys/power/state ]] || die "/sys/power/state is not readable."
grep -qw mem /sys/power/state || die "This kernel does not offer the mem sleep state."

exec 9>/run/lock/framework-microsd-resume.lock
flock -n 9 || die "Another validation run holds the lock."

root_source=$(findmnt -n -o SOURCE /) || die "Cannot identify the root source."
root_fstype=$(findmnt -n -o FSTYPE /) || die "Cannot identify the root filesystem."
root_options=$(findmnt -n -o OPTIONS /) || die "Cannot read root mount options."
[[ ,$root_options, == *,rw,* ]] || die "The root filesystem is not mounted read-write."
[[ -b $root_source ]] || die "Root source is not a directly resolvable block device: $root_source"

if ! root_chain=$(lsblk -s -n -o KNAME "$root_source" 2>&1); then
	die "Cannot resolve root backing devices: $root_chain"
fi

reader=
block=
usb_device=
transport_driver=
for device in /sys/class/scsi_device/*/device; do
	[[ -r $device/vendor && -r $device/model ]] || continue
	vendor=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' < "$device/vendor")
	model=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' < "$device/model")
	[[ $vendor == FRMW && $model == "MicroSD(2nd Gen)" ]] || continue

	for block_path in "$device"/block/*; do
		[[ -e $block_path ]] || continue
		candidate=${block_path##*/}
		grep -Fxq -- "$candidate" <<< "$root_chain" || continue
		[[ -z $reader ]] || die "More than one matching Framework reader backs root."
		reader=$device
		block=$candidate
	done
done

[[ -n $reader ]] || die "The Framework MicroSD (2nd Gen) reader does not back /."

parent=$(readlink -f -- "$reader") || die "Cannot resolve the reader's sysfs path."
while [[ $parent == /sys/* ]]; do
	if [[ -r $parent/idVendor && -r $parent/idProduct ]] &&
		[[ $(<"$parent/idVendor") == 32ac && $(<"$parent/idProduct") == 0026 ]]; then
		usb_device=$parent
	fi
	if [[ -L $parent/driver ]]; then
		driver_path=$(readlink -f -- "$parent/driver")
		[[ ${driver_path##*/} == usb-storage ]] && transport_driver=usb-storage
	fi
	parent=${parent%/*}
done

[[ -n $usb_device ]] || die "The root reader is not below USB device 32ac:0026."
[[ $transport_driver == usb-storage ]] || die "The root reader is not using usb-storage Bulk-Only transport."
[[ -r $usb_device/power/persist ]] || die "The root reader's USB persistence setting is unavailable."
[[ $(<"$usb_device/power/persist") == 1 ]] || die "USB persistence is disabled for the root reader."
[[ -r $reader/blacklist ]] || die "The reader's SCSI blacklist flags are unavailable."
flags=$(<"$reader/blacklist")
for flag in INQUIRY_36 IGN_MEDIA_CHANGE SKIP_IO_HINTS RETRY_MEDIA_CHANGE; do
	[[ " $flags " == *" $flag "* ]] || die "Missing live SCSI flag $flag (found: $flags)"
done

if [[ -r /sys/class/rtc/rtc0/wakealarm ]]; then
	alarm=$(</sys/class/rtc/rtc0/wakealarm)
	[[ -z $alarm || $alarm == 0 ]] || die "rtc0 already has a pending wake alarm: $alarm"
fi
rtcwake --mode show >/dev/null || die "rtcwake cannot access a usable RTC."

if ! cursor_output=$(journalctl -b -k -n 0 --show-cursor --no-pager -o cat 2>&1); then
	die "Cannot read the current-boot kernel journal: $cursor_output"
fi
cursor=$(sed -n 's/^-- cursor: //p' <<< "$cursor_output" | tail -n 1)
[[ -n $cursor ]] || die "journalctl did not return a cursor."

probe=$(mktemp "/.framework-microsd-resume.XXXXXX") || die "Cannot create a probe on /."
rtc_armed=false
cleanup() {
	if [[ $rtc_armed == true ]]; then
		rtcwake --mode disable >/dev/null 2>&1 || true
	fi
	rm -f -- "$probe"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'preflight=%s\n' "$(date --iso-8601=seconds)" > "$probe"
sync -f "$probe"
[[ $(findmnt -n -o TARGET --target "$probe") == / ]] || die "The probe is not on the root mount."

mem_sleep=unknown
if [[ -r /sys/power/mem_sleep ]]; then
	mem_sleep=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/power/mem_sleep)
	[[ -n $mem_sleep ]] || mem_sleep=unknown
fi

echo "Kernel: $(uname -r)"
echo "Root: $root_source ($root_fstype) via $block"
echo "Reader: ${reader%/device}"
echo "USB: ${usb_device##*/} (32ac:0026, $transport_driver, persist=1)"
echo "Flags: $flags"
echo "Active mem_sleep: $mem_sleep"

if [[ $check_only == true ]]; then
	echo "PASS: preflight and fsynced root write completed; no suspend was attempted."
	exit 0
fi

echo "Do not remove the card. The machine may wake before the RTC deadline."

block_re=$(sed 's/[][\\.^$*+?{}|()]/\\&/g' <<< "$block")
device_re="${block_re}([0-9]+|p[0-9]+)?"
fatal_pattern="device offline or changed|rejecting I/O to offline device|I/O error, dev ${device_re}([ ,:]|$)|Buffer I/O error on dev ${device_re}([ ,:]|$)|writeback error|XFS.*(metadata I/O error|log I/O error|shutdown|corruption)|EXT4-fs.*(error|aborting journal|remounting filesystem read-only)|BTRFS.*(error|forced readonly)"
ua_pattern='Unit Attention|medium may have changed'
early_wakes=0

for ((cycle = 1; cycle <= cycles; cycle++)); do
	echo "Suspend $cycle/$cycles; RTC deadline ${seconds}s"
	sync
	read -r before _ < /proc/uptime
	rtc_armed=true
	rtcwake --mode mem --seconds "$seconds"
	if ! rtcwake --mode disable >/dev/null; then
		die "Could not disable the RTC alarm after cycle $cycle."
	fi
	rtc_armed=false
	read -r after _ < /proc/uptime
	elapsed=$(awk -v start="$before" -v end="$after" 'BEGIN { printf "%.3f", end - start }')

	if awk -v elapsed="$elapsed" -v requested="$seconds" \
		'BEGIN { exit !(elapsed < requested * 0.8) }'; then
		((early_wakes += 1))
		printf 'Resumed after %ss (early wake).\n' "$elapsed"
	else
		printf 'Resumed after %ss.\n' "$elapsed"
	fi

	if ! printf 'resume=%d time=%s elapsed=%s\n' \
		"$cycle" "$(date --iso-8601=seconds)" "$elapsed" > "$probe"; then
		die "The post-resume root write failed on cycle $cycle."
	fi
	if ! sync -f "$probe"; then
		die "The post-resume root fsync failed on cycle $cycle."
	fi

	# Let late resume errors reach the kernel journal before declaring success.
	sleep 2
	if ! logs=$(journalctl -b -k --after-cursor "$cursor" --no-pager -o cat 2>&1); then
		die "Kernel journal read failed after cycle $cycle: $logs"
	fi
	if grep -Eiq "$fatal_pattern" <<< "$logs"; then
		echo "Storage error detected after resume $cycle:" >&2
		grep -Ei "$fatal_pattern" <<< "$logs" >&2
		exit 1
	fi
done

if ! logs=$(journalctl -b -k --after-cursor "$cursor" --no-pager -o cat 2>&1); then
	die "Final kernel journal read failed: $logs"
fi

entry_count=$(grep -Ec 'PM: suspend entry' <<< "$logs" || true)
exit_count=$(grep -Ec 'PM: suspend exit' <<< "$logs" || true)
ua_count=$(grep -Eic "$ua_pattern" <<< "$logs" || true)

if ((entry_count < cycles || exit_count < cycles)); then
	die "Journal recorded only $entry_count suspend entries and $exit_count exits for $cycles calls."
fi

echo "PASS: $cycles suspend/resume calls completed with fsynced root writes and no matching storage errors."
echo "Journal observed $entry_count suspend entries and $exit_count exits."
if ((early_wakes > 0)); then
	echo "WARNING: $early_wakes/$cycles cycles woke before 80% of the requested interval."
	echo "Use lid-close and longer manual tests to supplement these transitions."
fi
if ((ua_count > 0)); then
	echo "Note: $ua_count Unit Attention log lines occurred without a matching I/O failure."
fi
