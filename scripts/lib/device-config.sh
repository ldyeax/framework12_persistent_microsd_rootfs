# SPDX-License-Identifier: MIT

# This file is sourced by the repository's Bash helpers. It deliberately
# parses key=value data without eval or source.

sdroot_trim() {
	REPLY=$1
	REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
	REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

sdroot_config_defaults() {
	SDROOT_CFG_USB_ID=32ac:0026
	SDROOT_CFG_USB_PATH=any
	SDROOT_CFG_SCSI_VENDOR=FRMW
	SDROOT_CFG_SCSI_MODEL='MicroSD(2nd Gen)'
	SDROOT_CFG_SCSI_REVISION=any
	SDROOT_CFG_TRANSPORT=usb-storage
	SDROOT_CFG_TARGET=/
	SDROOT_CFG_RTC_DEVICE=/dev/rtc0
	SDROOT_CFG_ALLOW_MODEL_PREFIX=no
}

sdroot_config_assign() {
	local key=$1
	local value=$2

	case $key in
	usb_id) SDROOT_CFG_USB_ID=$value ;;
	usb_path) SDROOT_CFG_USB_PATH=$value ;;
	scsi_vendor) SDROOT_CFG_SCSI_VENDOR=$value ;;
	scsi_model) SDROOT_CFG_SCSI_MODEL=$value ;;
	scsi_revision) SDROOT_CFG_SCSI_REVISION=$value ;;
	transport) SDROOT_CFG_TRANSPORT=$value ;;
	target) SDROOT_CFG_TARGET=$value ;;
	rtc_device) SDROOT_CFG_RTC_DEVICE=$value ;;
	allow_model_prefix) SDROOT_CFG_ALLOW_MODEL_PREFIX=$value ;;
	*)
		printf 'Unknown device config key: %s\n' "$key" >&2
		return 1
		;;
	esac
}

sdroot_config_load() {
	local path=$1
	local line key value
	local line_number=0
	local -A seen=()

	[[ -r $path ]] || {
		printf 'Device config is not readable: %s\n' "$path" >&2
		return 1
	}

	while IFS= read -r line || [[ -n $line ]]; do
		((line_number += 1))
		line=${line%$'\r'}
		sdroot_trim "$line"
		line=$REPLY
		[[ -z $line || $line == \#* ]] && continue
		[[ $line == *=* ]] || {
			printf '%s:%d: expected key=value\n' "$path" "$line_number" >&2
			return 1
		}

		key=${line%%=*}
		value=${line#*=}
		sdroot_trim "$key"
		key=$REPLY
		sdroot_trim "$value"
		value=$REPLY

		[[ -n $key ]] || {
			printf '%s:%d: empty key\n' "$path" "$line_number" >&2
			return 1
		}
		[[ ! ${seen[$key]+present} ]] || {
			printf '%s:%d: duplicate key %s\n' "$path" "$line_number" "$key" >&2
			return 1
		}
		seen[$key]=1
		sdroot_config_assign "$key" "$value" || return 1
	done < "$path"
}

sdroot_config_default_path() {
	local repo_root=$1

	if [[ -n ${SDROOT_CONFIG:-} ]]; then
		REPLY=$SDROOT_CONFIG
	elif [[ -r /etc/framework-microsd-rootfs.conf ]]; then
		REPLY=/etc/framework-microsd-rootfs.conf
	else
		REPLY=$repo_root/config/device.conf
	fi
}

sdroot_config_find_arg() {
	local repo_root=$1
	shift
	local -a args=("$@")
	local index

	sdroot_config_default_path "$repo_root"
	SDROOT_CONFIG_PATH=$REPLY

	for ((index = 0; index < ${#args[@]}; index++)); do
		case ${args[index]} in
		--)
			break
			;;
		--config)
			((index + 1 < ${#args[@]})) || {
				echo "--config requires a file." >&2
				return 2
			}
			SDROOT_CONFIG_PATH=${args[index + 1]}
			((index += 1))
			;;
		--config=*)
			SDROOT_CONFIG_PATH=${args[index]#*=}
			;;
		--usb-id|--usb-path|--usb-slot|--scsi-vendor|--scsi-model|\
		--scsi-revision|--transport|--target|--rtc-device|\
		--destination|--portage-slot|--config-destination|--cycles|\
		--suspend-seconds)
			((index + 1 < ${#args[@]})) || continue
			((index += 1))
			;;
		esac
	done
}

sdroot_config_apply_env() {
	[[ ${SDROOT_USB_ID+x} ]] && SDROOT_CFG_USB_ID=$SDROOT_USB_ID
	[[ ${SDROOT_USB_PATH+x} ]] && SDROOT_CFG_USB_PATH=$SDROOT_USB_PATH
	[[ ${SDROOT_SCSI_VENDOR+x} ]] && SDROOT_CFG_SCSI_VENDOR=$SDROOT_SCSI_VENDOR
	[[ ${SDROOT_SCSI_MODEL+x} ]] && SDROOT_CFG_SCSI_MODEL=$SDROOT_SCSI_MODEL
	[[ ${SDROOT_SCSI_REVISION+x} ]] && SDROOT_CFG_SCSI_REVISION=$SDROOT_SCSI_REVISION
	[[ ${SDROOT_TRANSPORT+x} ]] && SDROOT_CFG_TRANSPORT=$SDROOT_TRANSPORT
	[[ ${SDROOT_TARGET+x} ]] && SDROOT_CFG_TARGET=$SDROOT_TARGET
	[[ ${SDROOT_RTC_DEVICE+x} ]] && SDROOT_CFG_RTC_DEVICE=$SDROOT_RTC_DEVICE
	[[ ${SDROOT_ALLOW_MODEL_PREFIX+x} ]] && SDROOT_CFG_ALLOW_MODEL_PREFIX=$SDROOT_ALLOW_MODEL_PREFIX
	return 0
}

sdroot_config_prepare() {
	local repo_root=$1
	shift

	sdroot_config_defaults
	sdroot_config_find_arg "$repo_root" "$@" || return
	sdroot_config_load "$SDROOT_CONFIG_PATH" || return
	sdroot_config_apply_env
}

sdroot_config_validate() {
	local inquiry_pattern='^[A-Za-z0-9][A-Za-z0-9._+()/ -]*$'
	local usb_path_pattern='^[A-Za-z0-9._:+-]+$'

	sdroot_trim "$SDROOT_CFG_SCSI_VENDOR"
	SDROOT_CFG_SCSI_VENDOR=$REPLY
	sdroot_trim "$SDROOT_CFG_SCSI_MODEL"
	SDROOT_CFG_SCSI_MODEL=$REPLY
	sdroot_trim "$SDROOT_CFG_SCSI_REVISION"
	SDROOT_CFG_SCSI_REVISION=$REPLY

	SDROOT_CFG_USB_ID=${SDROOT_CFG_USB_ID,,}
	[[ $SDROOT_CFG_USB_ID =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || {
		printf 'Invalid USB ID %q; expected four hex digits, a colon, and four hex digits.\n' "$SDROOT_CFG_USB_ID" >&2
		return 2
	}
	SDROOT_CFG_USB_VENDOR=${SDROOT_CFG_USB_ID%:*}
	SDROOT_CFG_USB_PRODUCT=${SDROOT_CFG_USB_ID#*:}

	if [[ $SDROOT_CFG_USB_PATH != any && ! $SDROOT_CFG_USB_PATH =~ $usb_path_pattern ]]; then
		printf 'Invalid USB ID_PATH %q.\n' "$SDROOT_CFG_USB_PATH" >&2
		return 2
	fi

	[[ ${#SDROOT_CFG_SCSI_VENDOR} -ge 1 && ${#SDROOT_CFG_SCSI_VENDOR} -le 8 && $SDROOT_CFG_SCSI_VENDOR =~ $inquiry_pattern ]] || {
		printf 'Invalid SCSI vendor %q; use 1-8 safe ASCII inquiry characters.\n' "$SDROOT_CFG_SCSI_VENDOR" >&2
		return 2
	}
	[[ ${#SDROOT_CFG_SCSI_MODEL} -ge 1 && ${#SDROOT_CFG_SCSI_MODEL} -le 16 && $SDROOT_CFG_SCSI_MODEL =~ $inquiry_pattern ]] || {
		printf 'Invalid SCSI model %q; use 1-16 safe ASCII inquiry characters.\n' "$SDROOT_CFG_SCSI_MODEL" >&2
		return 2
	}

	case ${SDROOT_CFG_ALLOW_MODEL_PREFIX,,} in
	yes | true | 1) SDROOT_CFG_ALLOW_MODEL_PREFIX=yes ;;
	no | false | 0) SDROOT_CFG_ALLOW_MODEL_PREFIX=no ;;
	*)
		printf 'Invalid allow_model_prefix value %q; expected yes or no.\n' "$SDROOT_CFG_ALLOW_MODEL_PREFIX" >&2
		return 2
		;;
	esac
	if [[ ${#SDROOT_CFG_SCSI_MODEL} -lt 16 && $SDROOT_CFG_ALLOW_MODEL_PREFIX != yes ]]; then
		printf 'SCSI devinfo model matching is prefix-based; model %q is shorter than 16 characters.\n' "$SDROOT_CFG_SCSI_MODEL" >&2
		echo "Set allow_model_prefix=yes only after reviewing the broader match." >&2
		return 2
	fi

	if [[ $SDROOT_CFG_SCSI_REVISION != any ]]; then
		[[ ${#SDROOT_CFG_SCSI_REVISION} -ge 1 && ${#SDROOT_CFG_SCSI_REVISION} -le 4 && $SDROOT_CFG_SCSI_REVISION =~ $inquiry_pattern ]] || {
			printf 'Invalid SCSI revision %q; expected any or 1-4 safe ASCII characters.\n' "$SDROOT_CFG_SCSI_REVISION" >&2
			return 2
		}
	fi

	[[ $SDROOT_CFG_TRANSPORT =~ ^[A-Za-z0-9_-]+$ ]] || {
		printf 'Invalid transport driver %q.\n' "$SDROOT_CFG_TRANSPORT" >&2
		return 2
	}
	sdroot_trim "$SDROOT_CFG_TARGET"
	[[ $REPLY == "$SDROOT_CFG_TARGET" ]] || {
		printf 'Target cannot have leading or trailing whitespace: %q\n' "$SDROOT_CFG_TARGET" >&2
		return 2
	}
	[[ $SDROOT_CFG_TARGET == /* && $SDROOT_CFG_TARGET != *$'\n'* && $SDROOT_CFG_TARGET != *$'\r'* ]] || {
		printf 'Target must be an absolute path without newlines: %q\n' "$SDROOT_CFG_TARGET" >&2
		return 2
	}
	while [[ $SDROOT_CFG_TARGET != / && $SDROOT_CFG_TARGET == */ ]]; do
		SDROOT_CFG_TARGET=${SDROOT_CFG_TARGET%/}
	done
	[[ $SDROOT_CFG_RTC_DEVICE =~ ^/dev/rtc[0-9]+$ ]] || {
		printf 'Invalid RTC device %q; expected /dev/rtcN.\n' "$SDROOT_CFG_RTC_DEVICE" >&2
		return 2
	}
}

sdroot_config_print() {
	cat <<EOF
Config: $SDROOT_CONFIG_PATH
USB ID: $SDROOT_CFG_USB_ID
USB physical path: $SDROOT_CFG_USB_PATH
SCSI inquiry: $SDROOT_CFG_SCSI_VENDOR / $SDROOT_CFG_SCSI_MODEL / $SDROOT_CFG_SCSI_REVISION
Transport: $SDROOT_CFG_TRANSPORT
Target mount: $SDROOT_CFG_TARGET
RTC device: $SDROOT_CFG_RTC_DEVICE
Allow SCSI model prefix: $SDROOT_CFG_ALLOW_MODEL_PREFIX
EOF
}

sdroot_config_emit() {
	cat <<EOF
# Generated by install-gentoo-patches.sh. Edit through a reviewed config and
# reinstall so the patch identity and runtime guards remain synchronized.
usb_id=$SDROOT_CFG_USB_ID
usb_path=$SDROOT_CFG_USB_PATH
scsi_vendor=$SDROOT_CFG_SCSI_VENDOR
scsi_model=$SDROOT_CFG_SCSI_MODEL
scsi_revision=$SDROOT_CFG_SCSI_REVISION
transport=$SDROOT_CFG_TRANSPORT
target=$SDROOT_CFG_TARGET
rtc_device=$SDROOT_CFG_RTC_DEVICE
allow_model_prefix=$SDROOT_CFG_ALLOW_MODEL_PREFIX
EOF
}

sdroot_read_scsi_identity() {
	local device=$1

	sdroot_trim "$(<"$device/vendor")"
	SDROOT_FOUND_SCSI_VENDOR=$REPLY
	sdroot_trim "$(<"$device/model")"
	SDROOT_FOUND_SCSI_MODEL=$REPLY
	sdroot_trim "$(<"$device/rev")"
	SDROOT_FOUND_SCSI_REVISION=$REPLY
}

sdroot_scsi_matches() {
	local device=$1
	sdroot_read_scsi_identity "$device"
	[[ $SDROOT_FOUND_SCSI_VENDOR == "$SDROOT_CFG_SCSI_VENDOR" &&
		$SDROOT_FOUND_SCSI_MODEL == "$SDROOT_CFG_SCSI_MODEL" ]] || return 1
	[[ $SDROOT_CFG_SCSI_REVISION == any ||
		$SDROOT_FOUND_SCSI_REVISION == "$SDROOT_CFG_SCSI_REVISION" ]]
}

sdroot_usb_id_matches() {
	local usb_device=$1
	[[ -r $usb_device/idVendor && -r $usb_device/idProduct ]] || return 1
	[[ ${SDROOT_CFG_USB_VENDOR} == "$(<"$usb_device/idVendor")" &&
		${SDROOT_CFG_USB_PRODUCT} == "$(<"$usb_device/idProduct")" ]]
}

sdroot_usb_id_path() {
	local usb_device=$1
	command -v udevadm >/dev/null || return 1
	REPLY=$(udevadm info --query=property --property=ID_PATH --value \
		--path="$usb_device" 2>/dev/null | head -n 1)
	[[ -n $REPLY ]]
}

sdroot_usb_matches() {
	local usb_device=$1
	sdroot_usb_id_matches "$usb_device" || return 1
	[[ $SDROOT_CFG_USB_PATH == any ]] && return 0
	sdroot_usb_id_path "$usb_device" || return 1
	[[ $REPLY == "$SDROOT_CFG_USB_PATH" ]]
}

sdroot_ere_escape() {
	REPLY=$(printf '%s' "$1" | sed 's/[][\\.^$*+?{}|()]/\\&/g')
}
