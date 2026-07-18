#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: install-gentoo-patches.sh [--replace] [--destination DIR]

Install the ordered patch series for Gentoo's sys-kernel/gentoo-sources.
Set --destination only for staging or testing. Existing differing files are
left untouched unless --replace is given.
EOF
}

replace=false
destination=/etc/portage/patches/sys-kernel/gentoo-sources

while (($#)); do
	case $1 in
	--replace)
		replace=true
		shift
		;;
	--destination)
		[[ $# -ge 2 ]] || {
			usage >&2
			exit 2
		}
		destination=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

if [[ $destination == /etc/* && $EUID -ne 0 ]]; then
	echo "Run as root when installing below /etc." >&2
	exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
patch_dir=$repo_root/patches

(
	cd -- "$patch_dir"
	sha256sum -c SHA256SUMS
)

install -d -m 0755 -- "$destination"

# Check the entire destination before changing either member of the series.
for name in \
	0001-scsi-sd-handle-framework-microsd-resume.patch \
	0002-scsi-retry-quirked-media-change.patch; do
	source_file=$patch_dir/$name
	target_file=$destination/$name

	if [[ -e $target_file || -L $target_file ]]; then
		if [[ ! -f $target_file || -L $target_file ]]; then
			echo "Refusing non-regular or symlink target: $target_file" >&2
			exit 1
		fi
	fi

	if [[ -e $target_file ]] && ! cmp -s -- "$source_file" "$target_file"; then
		if [[ $replace != true ]]; then
			echo "Refusing to replace differing file: $target_file" >&2
			echo "Review it, then rerun with --replace if appropriate." >&2
			exit 1
		fi
	fi
done

for name in \
	0001-scsi-sd-handle-framework-microsd-resume.patch \
	0002-scsi-retry-quirked-media-change.patch; do
	source_file=$patch_dir/$name
	target_file=$destination/$name

	if [[ -e $target_file ]] && ! cmp -s -- "$source_file" "$target_file"; then
		printf 'Replacing %s\n' "$target_file"
	fi

	install -T -m 0644 -- "$source_file" "$target_file"
done

printf 'Installed ordered patch series in %s\n' "$destination"
echo "It will be applied when Portage prepares a fresh gentoo-sources tree."
