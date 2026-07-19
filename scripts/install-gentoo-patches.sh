#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
# shellcheck source=lib/device-config.sh
source "$script_dir/lib/device-config.sh"

usage() {
	cat <<'EOF'
Usage: install-gentoo-patches.sh [options]

Patch installation:
  --destination DIR          Portage patch directory
  --portage-slot SLOT        Use gentoo-sources:SLOT patch directory
  --replace                  Replace differing regular target files
  --config-destination FILE  Persist the resolved runtime profile here
  --no-config-install        Do not persist a runtime profile

Target profile (CLI overrides environment and --config):
  --config FILE              Read a key=value device profile
  --usb-id VID:PID           USB vendor/product ID (default 32ac:0026)
  --usb-path ID_PATH         Constrain a physical slot by udev ID_PATH
  --usb-slot ID_PATH         Alias for --usb-path
  --scsi-vendor VENDOR       SCSI inquiry vendor used by the kernel quirk
  --scsi-model MODEL         SCSI inquiry model used by the kernel quirk
  --scsi-revision REV|any    Runtime validation guard only
  --transport DRIVER         Runtime USB transport guard
  --target MOUNTPOINT        Filesystem validated by the resume test
  --rtc-device /dev/rtcN     RTC used by the resume test
  --allow-model-prefix       Permit a broad SCSI model-prefix match
  --no-allow-model-prefix    Reject a broad SCSI model-prefix match
  --show-config              Print the resolved profile without installing

USB ID/path and SCSI revision constrain runtime validation; the kernel quirk
itself is selected only by SCSI vendor/model. --destination and
--portage-slot are mutually exclusive.
EOF
}

replace=false
destination=/etc/portage/patches/sys-kernel/gentoo-sources
destination_explicit=false
portage_slot=
config_destination=auto
install_config=true
show_config=false

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
	--replace)
		replace=true
		shift
		;;
	--destination)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		destination=$2
		destination_explicit=true
		shift 2
		;;
	--portage-slot)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		portage_slot=$2
		shift 2
		;;
	--config-destination)
		[[ $# -ge 2 ]] || { usage >&2; exit 2; }
		config_destination=$2
		shift 2
		;;
	--no-config-install)
		install_config=false
		shift
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
	--show-config)
		show_config=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

sdroot_config_validate

if [[ -n $portage_slot ]]; then
	[[ $destination_explicit == false ]] || {
		echo "--destination and --portage-slot are mutually exclusive." >&2
		exit 2
	}
	[[ $portage_slot =~ ^[A-Za-z0-9._+-]+$ ]] || {
		printf 'Invalid Portage slot: %q\n' "$portage_slot" >&2
		exit 2
	}
	destination=/etc/portage/patches/sys-kernel/gentoo-sources:$portage_slot
fi

if [[ $show_config == true ]]; then
	sdroot_config_print
	printf 'Portage patch destination: %s\n' "$destination"
	exit 0
fi

if [[ $install_config == false ]]; then
	config_destination=
fi

command -v realpath >/dev/null || {
	echo "Required command not found: realpath" >&2
	exit 1
}
destination_resolved=$(realpath -m -- "$destination")
if [[ -e $destination || -L $destination ]]; then
	if [[ ! -d $destination || -L $destination ]]; then
		printf 'Refusing non-directory or symlink destination: %s\n' "$destination" >&2
		exit 1
	fi
fi

if [[ $config_destination == auto ]]; then
	case $destination_resolved in
	/etc/portage/patches/sys-kernel/gentoo-sources|\
	/etc/portage/patches/sys-kernel/gentoo-sources:*)
		config_destination=/etc/framework-microsd-rootfs.conf
		;;
	*) config_destination= ;;
	esac
fi

if [[ -n $config_destination ]]; then
	config_destination_resolved=$(realpath -m -- "$config_destination")
	if [[ -L $config_destination ]]; then
		printf 'Refusing symlink config destination: %s\n' "$config_destination" >&2
		exit 1
	fi
	if [[ $destination_resolved == "$config_destination_resolved" ||
		$destination_resolved == "$config_destination_resolved"/* ||
		$config_destination_resolved == "$destination_resolved"/* ]]; then
		printf 'Config destination cannot be inside, equal to, or a parent of the patch directory: %s\n' \
			"$config_destination" >&2
		exit 1
	fi
	config_destination=$config_destination_resolved
fi
destination=$destination_resolved

if [[ $destination == /etc/* && $EUID -ne 0 ]] ||
	[[ -n $config_destination && $config_destination == /etc/* && $EUID -ne 0 ]]; then
	echo "Run as root when installing below /etc." >&2
	exit 2
fi

patch_dir=$repo_root/patches
(
	cd -- "$patch_dir"
	sha256sum -c SHA256SUMS
)

render_dir=$(mktemp -d /tmp/framework-sdroot-patches.XXXXXX)
cleanup() {
	rm -f -- "$render_dir"/*
	rmdir -- "$render_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for name in \
	0001-scsi-sd-handle-framework-microsd-resume.patch \
	0002-scsi-retry-quirked-media-change.patch; do
	cp -- "$patch_dir/$name" "$render_dir/$name"
done

match_name=0090-scsi-device-match.patch
template=$patch_dir/$match_name.in
rendered=$render_dir/$match_name
while IFS= read -r line || [[ -n $line ]]; do
	line=${line//@SCSI_VENDOR@/$SDROOT_CFG_SCSI_VENDOR}
	line=${line//@SCSI_MODEL@/$SDROOT_CFG_SCSI_MODEL}
	printf '%s\n' "$line"
done < "$template" > "$rendered"

if grep -Fq '@SCSI_' "$rendered"; then
	echo "Generated match patch still contains an unresolved placeholder." >&2
	exit 1
fi
expected_entry="{\"$SDROOT_CFG_SCSI_VENDOR\", \"$SDROOT_CFG_SCSI_MODEL\", NULL,"
[[ $(grep -Fc "$expected_entry" "$rendered") -eq 1 ]] || {
	echo "Generated match patch does not contain exactly one configured entry." >&2
	exit 1
}

if [[ $SDROOT_CFG_SCSI_VENDOR == FRMW && $SDROOT_CFG_SCSI_MODEL == 'MicroSD(2nd Gen)' ]]; then
	cmp -s -- "$rendered" "$patch_dir/$match_name" || {
		echo "Default rendered match patch differs from the checked-in artifact." >&2
		exit 1
	}
else
	echo "WARNING: the configured SCSI identity is not the runtime-tested device."
fi

profile_file=$render_dir/framework-microsd-rootfs.conf
sdroot_config_emit > "$profile_file"

names=(
	0001-scsi-sd-handle-framework-microsd-resume.patch
	0002-scsi-retry-quirked-media-change.patch
	0090-scsi-device-match.patch
)

# Validate every destination before changing any member of the series.
for name in "${names[@]}"; do
	source_file=$render_dir/$name
	target_file=$destination/$name

	if [[ -e $target_file || -L $target_file ]]; then
		if [[ ! -f $target_file || -L $target_file ]]; then
			printf 'Refusing non-regular or symlink target: %s\n' "$target_file" >&2
			exit 1
		fi
		if ! cmp -s -- "$source_file" "$target_file" && [[ $replace != true ]]; then
			printf 'Refusing to replace differing file: %s\n' "$target_file" >&2
			echo "Review it, then rerun with --replace if appropriate." >&2
			exit 1
		fi
	fi
done

if [[ -n $config_destination && ( -e $config_destination || -L $config_destination ) ]]; then
	if [[ ! -f $config_destination || -L $config_destination ]]; then
		printf 'Refusing non-regular or symlink config target: %s\n' "$config_destination" >&2
		exit 1
	fi
	if ! cmp -s -- "$profile_file" "$config_destination" && [[ $replace != true ]]; then
		printf 'Refusing to replace differing config: %s\n' "$config_destination" >&2
		echo "Review it, then rerun with --replace if appropriate." >&2
		exit 1
	fi
fi

if [[ -n $config_destination ]]; then
	config_parent=$(dirname -- "$config_destination")
	if [[ -e $config_parent || -L $config_parent ]]; then
		if [[ ! -d $config_parent || -L $config_parent ]]; then
			printf 'Refusing non-directory or symlink config parent: %s\n' \
				"$config_parent" >&2
			exit 1
		fi
	else
		install -d -m 0755 -- "$config_parent"
	fi
fi
if [[ ! -d $destination ]]; then
	install -d -m 0755 -- "$destination"
fi
for name in "${names[@]}"; do
	source_file=$render_dir/$name
	target_file=$destination/$name
	if [[ -e $target_file ]] && ! cmp -s -- "$source_file" "$target_file"; then
		printf 'Replacing %s\n' "$target_file"
	fi
	install -T -m 0644 -- "$source_file" "$target_file"
done

if [[ -n $config_destination ]]; then
	install -T -m 0644 -- "$profile_file" "$config_destination"
fi

sdroot_config_print
printf 'Installed ordered patch series in %s\n' "$destination"
if [[ -n $config_destination ]]; then
	printf 'Installed runtime profile in %s\n' "$config_destination"
fi
echo "Rendered patch checksums:"
sha256sum "${names[@]/#/$render_dir/}"
echo "The kernel quirk is keyed by SCSI vendor/model, not USB ID or physical slot."
echo "The patch series will be applied when Portage prepares a fresh source tree."
