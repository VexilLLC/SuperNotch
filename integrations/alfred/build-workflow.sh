#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:-"$SCRIPT_DIR/SuperNotch.alfredworkflow"}

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac

if ! command -v plutil >/dev/null 2>&1; then
    echo "build-workflow.sh requires macOS plutil" >&2
    exit 1
fi

plutil -lint "$SCRIPT_DIR/info.plist" >/dev/null

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/supernotch-alfred.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
cp "$SCRIPT_DIR/info.plist" "$tmp_dir/info.plist"

mkdir -p "$(dirname -- "$OUTPUT")"
rm -f "$OUTPUT"
# Archive the temporary directory's contents so Alfred finds info.plist at the
# root of the .alfredworkflow package (rather than inside a random temp folder).
ditto -c -k --sequesterRsrc "$tmp_dir/." "$OUTPUT"
echo "$OUTPUT"
