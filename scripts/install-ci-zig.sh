#!/usr/bin/env bash
set -euo pipefail
unset BASH_ENV CDPATH ENV GLOBIGNORE
IFS=$' \t\n'

readonly version=0.13.0
readonly archive_sha256=d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea
readonly archive_url=https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
destination="${1:-}"
[[ "$#" -eq 1 && "$destination" == /* && "$destination" != / ]] || {
	echo "CI Zig destination must be one safe absolute path" >&2
	exit 1
}
[[ "$(uname -s):$(uname -m)" == Linux:x86_64 ]] || {
	echo "reviewed CI Zig bootstrap supports only Linux x86_64" >&2
	exit 1
}
[[ ! -e "$destination" && ! -L "$destination" ]] || {
	echo "CI Zig destination already exists" >&2
	exit 1
}

archive="$(mktemp /tmp/zig-0.13.0.XXXXXX.tar.xz)"
extract_root="$(mktemp -d /tmp/zig-0.13.0.XXXXXX)"
cleanup() {
	local status=$?
	trap - EXIT HUP INT TERM
	rm -f "$archive"
	rm -rf "$extract_root"
	exit "$status"
}
trap cleanup EXIT HUP INT TERM
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
	--connect-timeout 15 --max-time 180 -o "$archive" "$archive_url"
printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum --check --strict - >/dev/null
tar -xJf "$archive" -C "$extract_root" --no-same-owner --no-same-permissions
source_root="$extract_root/zig-linux-x86_64-$version"
[[ -x "$source_root/zig" && ! -L "$source_root/zig" ]] || {
	echo "reviewed Zig archive layout is invalid" >&2
	exit 1
}
mv "$source_root" "$destination"
[[ "$("$destination"/zig version)" == "$version" ]] || {
	echo "installed Zig version differs from the reviewed pin" >&2
	exit 1
}
printf '%s\n' "$destination"
