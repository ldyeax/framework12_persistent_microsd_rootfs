#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
# shellcheck source=lib/device-config.sh
source "$script_dir/lib/device-config.sh"

usage() {
	cat <<'EOF'
Usage: validate-resume.sh [options] [cycles] [suspend-seconds]

Modes:
  --check                    Run preflight and an fsynced target write only
  --show-config              Print the resolved profile without system access
  --cycles N                 Number of suspend cycles (default 20)
  --suspend-seconds N        RTC deadline per cycle (default 15)

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

The target device is always derived from the configured mount's block ancestry;
no /dev/sdX name or SCSI address is assumed.
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

check_only=false
show_config=false
cycles=20
seconds=15
cycles_explicit=false
seconds_explicit=false
positionals=()

for argument in "$@"; do
	case $argument in
	-h | --help)
		usage
		exit 0
		;;
	esac
done

sdroot_config_prepare "$repo_root" "$@"

while (($#)); do
	case $1 in
	--check)
		check_only=true
		shift
		;;
	--show-config)
		show_config=true
		shift
		;;
	--cycles)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		cycles=$2
		cycles_explicit=true
		shift 2
		;;
	--suspend-seconds)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		seconds=$2
		seconds_explicit=true
		shift 2
		;;
	--config)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		shift 2
		;;
	--config=*)
		shift
		;;
	--usb-id)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_USB_ID=$2
		shift 2
		;;
	--usb-path | --usb-slot)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_USB_PATH=$2
		shift 2
		;;
	--scsi-vendor)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_SCSI_VENDOR=$2
		shift 2
		;;
	--scsi-model)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_SCSI_MODEL=$2
		shift 2
		;;
	--scsi-revision)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_SCSI_REVISION=$2
		shift 2
		;;
	--transport)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_TRANSPORT=$2
		shift 2
		;;
	--target)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_TARGET=$2
		shift 2
		;;
	--rtc-device)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		SDROOT_CFG_RTC_DEVICE=$2
		shift 2
		;;
	--allow-model-prefix)
		SDROOT_CFG_ALLOW_MODEL_PREFIX=yes
		shift
		;;
	--no-allow-model-prefix)
		SDROOT_CFG_ALLOW_MODEL_PREFIX=no
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		while (($#)); do positionals+=("$1"); shift; done
		;;
	-*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	*)
		positionals+=("$1")
		shift
		;;
	esac
done

if ((${#positionals[@]} > 2)); then
	usage >&2
	exit 2
fi
if ((${#positionals[@]} >= 1)); then
	[[ $cycles_explicit == false ]] || die "Do not combine positional cycles with --cycles."
	cycles=${positionals[0]}
fi
if ((${#positionals[@]} == 2)); then
	[[ $seconds_explicit == false ]] || die "Do not combine positional seconds with --suspend-seconds."
	seconds=${positionals[1]}
fi

[[ $cycles =~ ^[1-9][0-9]*$ && $seconds =~ ^[1-9][0-9]*$ ]] || {
	usage >&2
	exit 2
}
sdroot_config_validate

if [[ $show_config == true ]]; then
	sdroot_config_print
	printf 'Cycles: %s\nSuspend seconds: %s\n' "$cycles" "$seconds"
	exit 0
fi

[[ $EUID -eq 0 ]] || die "Run as root."

required=(awk date findmnt flock grep journalctl lsblk mktemp readlink rm rtcwake sed sleep sync tail tr uname)
if [[ $SDROOT_CFG_USB_PATH != any ]]; then
	required+=(udevadm)
fi
for command_name in "${required[@]}"; do
	command -v "$command_name" >/dev/null || die "Required command not found: $command_name"
done

[[ -r /sys/power/state ]] || die "/sys/power/state is not readable."
grep -qw mem /sys/power/state || die "This kernel does not offer the mem sleep state."

exec 9>/run/lock/framework-microsd-resume.lock
flock -n 9 || die "Another validation run holds the lock."

target=$SDROOT_CFG_TARGET
target_mount=$(findmnt -n -o TARGET -M "$target") || die "$target is not a mount point."
[[ $target_mount == "$target" ]] || die "Configured target $target resolves to mount $target_mount."
target_source=$(findmnt -n -o SOURCE -M "$target") || die "Cannot identify the target source."
target_fstype=$(findmnt -n -o FSTYPE -M "$target") || die "Cannot identify the target filesystem."
target_options=$(findmnt -n -o OPTIONS -M "$target") || die "Cannot read target mount options."
[[ ,$target_options, == *,rw,* ]] || die "The target filesystem is not mounted read-write."
[[ -b $target_source ]] || die "Target source is not a directly resolvable block device: $target_source"

if ! target_chain=$(lsblk -srn -o KNAME "$target_source" 2>&1); then
	die "Cannot resolve target backing devices: $target_chain"
fi

reader=
reader_revision=
block=
usb_device=
usb_id_path=unavailable
usb_interface=
transport_driver=unbound
for device in /sys/class/scsi_device/*/device; do
	[[ -r $device/vendor && -r $device/model && -r $device/rev ]] || continue
	sdroot_scsi_matches "$device" || continue

	for block_path in "$device"/block/*; do
		[[ -e $block_path ]] || continue
		candidate=${block_path##*/}
		grep -Fxq -- "$candidate" <<< "$target_chain" || continue
		if [[ -n $reader && $reader != "$device" ]]; then
			die "More than one configured SCSI reader backs $target."
		fi
		reader=$device
		reader_revision=$SDROOT_FOUND_SCSI_REVISION
		block=$candidate
	done
done

[[ -n $reader ]] || die "Configured SCSI reader does not back $target."
[[ -r /sys/class/block/$block/removable ]] ||
	die "Target reader's removable-media state is unavailable."
[[ $(<"/sys/class/block/$block/removable") == 1 ]] ||
	die "Target SCSI disk $block is not removable; this workaround does not apply."

parent=$(readlink -f -- "$reader") || die "Cannot resolve the reader's sysfs path."
while [[ $parent == /sys/* ]]; do
	if [[ -r $parent/bInterfaceClass && -L $parent/driver ]]; then
		candidate_usb=${parent%/*}
		if [[ -r $candidate_usb/idVendor && -r $candidate_usb/idProduct ]]; then
			usb_interface=$parent
			usb_device=$candidate_usb
			driver_path=$(readlink -f -- "$parent/driver")
			transport_driver=${driver_path##*/}
			break
		fi
	fi
	parent=${parent%/*}
done

[[ -n $usb_interface ]] || die "Target SCSI reader has no USB storage interface ancestor."
sdroot_usb_id_matches "$usb_device" ||
	die "Target reader USB device does not match $SDROOT_CFG_USB_ID."
if sdroot_usb_id_path "$usb_device"; then
	usb_id_path=$REPLY
fi
[[ $SDROOT_CFG_USB_PATH == any || $usb_id_path == "$SDROOT_CFG_USB_PATH" ]] ||
	die "Target reader ID_PATH is $usb_id_path, not $SDROOT_CFG_USB_PATH."
[[ $transport_driver == "$SDROOT_CFG_TRANSPORT" ]] ||
	die "Target reader interface ${usb_interface##*/} uses $transport_driver, not $SDROOT_CFG_TRANSPORT."
[[ -r $usb_device/power/persist ]] || die "The target reader's USB persistence setting is unavailable."
[[ $(<"$usb_device/power/persist") == 1 ]] || die "USB persistence is disabled for the target reader."
[[ -r $reader/blacklist ]] || die "The reader's SCSI blacklist flags are unavailable."
flags=$(<"$reader/blacklist")
for flag in INQUIRY_36 IGN_MEDIA_CHANGE SKIP_IO_HINTS RETRY_MEDIA_CHANGE; do
	[[ " $flags " == *" $flag "* ]] || die "Missing live SCSI flag $flag (found: $flags)"
done

rtc_name=${SDROOT_CFG_RTC_DEVICE##*/}
rtc_alarm=/sys/class/rtc/$rtc_name/wakealarm
[[ -r $rtc_alarm ]] || die "Cannot establish pending-alarm state from $rtc_alarm."
alarm=$(<"$rtc_alarm")
[[ -z $alarm || $alarm == 0 ]] || die "$rtc_name already has a pending wake alarm: $alarm"
rtcwake --device "$SDROOT_CFG_RTC_DEVICE" --mode show >/dev/null || die "rtcwake cannot access $SDROOT_CFG_RTC_DEVICE."

if ! cursor_output=$(journalctl -b -k -n 0 --show-cursor --no-pager -o cat 2>&1); then
	die "Cannot read the current-boot kernel journal: $cursor_output"
fi
cursor=$(sed -n 's/^-- cursor: //p' <<< "$cursor_output" | tail -n 1)
[[ -n $cursor ]] || die "journalctl did not return a cursor."

if [[ $target == / ]]; then
	probe_pattern=/.framework-microsd-resume.XXXXXX
else
	probe_pattern=$target/.framework-microsd-resume.XXXXXX
fi
probe=$(mktemp "$probe_pattern") || die "Cannot create a probe on $target."
rtc_armed=false
cleanup() {
	if [[ $rtc_armed == true ]]; then
		rtcwake --device "$SDROOT_CFG_RTC_DEVICE" --mode disable >/dev/null 2>&1 || true
	fi
	rm -f -- "$probe"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'preflight=%s\n' "$(date --iso-8601=seconds)" > "$probe"
sync -f "$probe"
[[ $(findmnt -n -o TARGET --target "$probe") == "$target" ]] || die "The probe is not on target mount $target."

mem_sleep=unknown
if [[ -r /sys/power/mem_sleep ]]; then
	mem_sleep=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/power/mem_sleep)
	[[ -n $mem_sleep ]] || mem_sleep=unknown
fi

echo "Kernel: $(uname -r)"
echo "Target: $target_source on $target ($target_fstype) via $block"
echo "Reader: ${reader%/device} ($SDROOT_CFG_SCSI_VENDOR / $SDROOT_CFG_SCSI_MODEL / $reader_revision)"
echo "USB: ${usb_device##*/} ($SDROOT_CFG_USB_ID, ID_PATH=$usb_id_path, $transport_driver, persist=1)"
echo "Flags: $flags"
echo "Active mem_sleep: $mem_sleep"

if [[ $check_only == true ]]; then
	echo "PASS: preflight and fsynced target write completed; no suspend was attempted."
	exit 0
fi

echo "Do not remove the card. The machine may wake before the RTC deadline."

sdroot_ere_escape "$block"
block_re=$REPLY
device_re="${block_re}([0-9]+|p[0-9]+)?"
fatal_pattern="device offline or changed|rejecting I/O to offline device|I/O error, dev ${device_re}([ ,:]|$)|Buffer I/O error on dev ${device_re}([ ,:]|$)|writeback error|XFS.*(metadata I/O error|log I/O error|shutdown|corruption)|EXT4-fs.*(error|aborting journal|remounting filesystem read-only)|BTRFS.*(error|forced readonly)"
ua_pattern='Unit Attention|medium may have changed'
early_wakes=0

for ((cycle = 1; cycle <= cycles; cycle++)); do
	echo "Suspend $cycle/$cycles; RTC deadline ${seconds}s"
	sync
	read -r before _ < /proc/uptime
	rtc_armed=true
	rtcwake --device "$SDROOT_CFG_RTC_DEVICE" --mode mem --seconds "$seconds"
	if ! rtcwake --device "$SDROOT_CFG_RTC_DEVICE" --mode disable >/dev/null; then
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
		die "The post-resume target write failed on cycle $cycle."
	fi
	if ! sync -f "$probe"; then
		die "The post-resume target fsync failed on cycle $cycle."
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

echo "PASS: $cycles suspend/resume calls completed with fsynced target writes and no matching storage errors."
echo "Journal observed $entry_count suspend entries and $exit_count exits."
if ((early_wakes > 0)); then
	echo "WARNING: $early_wakes/$cycles cycles woke before 80% of the requested interval."
	echo "Use lid-close and longer manual tests to supplement these transitions."
fi
if ((ua_count > 0)); then
	echo "Note: $ua_count Unit Attention log lines occurred without a matching I/O failure."
fi
