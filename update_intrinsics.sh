#!/bin/sh

# Deps:
#   - binwalk
#   - sed
#   - dd
#   - jq
#   - truncate (coreutils)
#   - stat (coreutils)

# Description:
#   rpk files are often used in conjuction with imx500 python demo scripts.
#   When used in this way, it is important to select the correct script for the
#   task (i.e. classification, segmentation, etc.). Certain networks also
#   require other paramaters to be set (such as fps) to achieve optimal
#   performance.
#
#   This script is able to update/add network_intrinsics to an .rpk file.
#
#   e.g:
#     update_network_intrinsics <RPK file> <JSON intrinsics file>
#
#   A JSON intrinsics file can be produced by invoking a demo-script with the
#   desired arguments with the addition of '--print-intrinsics'

set -e

if [ "$#" -ne 2 ]
then
  >&2 echo "Usage: update_network_intrinsics <RPK file> <JSON intrinsics file>"
  exit 1
fi

RPK_FILE="$(realpath "$1")"
INT_FILE="$(realpath "$2")"

if [ ! -f "$RPK_FILE" ] || [ ! -f "$INT_FILE" ]
then
  >&2 echo "Usage: update_network_intrinsics <RPK file> <JSON intrinsics file>"
  exit 1
fi

# Deps: binwalk / sed
calc_cpio_offset() {
  binwalk "$1" | \
    sed \
      --quiet \
      --regexp-extended \
        '/ASCII cpio archive/{s/^([[:digit:]]+).*/\1/; p; q}'
}

# Calculate offset of CPIO within .rpk file using binwalk
CPIO_OFFSET="$(calc_cpio_offset "$RPK_FILE")"
if [ -z "$CPIO_OFFSET" ]
then
  >&2 echo "ERROR: Could not calculate CPIO offset"
  exit 1
fi

# Use dd to extract CPIO archive
CPIO_ARCHIVE="$(mktemp)"
2>/dev/null \
  dd \
    ibs=1 \
    iseek="$CPIO_OFFSET" \
    if="$RPK_FILE" \
    of="$CPIO_ARCHIVE"

# Get order of files in CPIO file
FILE_LIST="$(mktemp)"
2>/dev/null \
  cpio \
    --file "$CPIO_ARCHIVE" \
    -t \
      > "$FILE_LIST"

# Append 'network_intrinsics' to file list if not already present
grep \
  --quiet \
  --line-regexp \
  --fixed-strings \
  network_intrinsics \
  "$FILE_LIST" || \
    echo network_intrinsics >> "$FILE_LIST"

CPIO_EXTRACT_DIR="$(mktemp -d)"
cd "$CPIO_EXTRACT_DIR"
2>/dev/null \
  cpio \
    --file "$CPIO_ARCHIVE" \
    --extract \
    --preserve-modification-time
cp "$INT_FILE" ./network_intrinsics
touch -t 314103141031.41 network_intrinsics

2>/dev/null \
  cpio \
    --create \
    --format=newc \
    --reproducible \
    --reset-access-time \
      < "$FILE_LIST" \
      > "$CPIO_ARCHIVE"
cd - >/dev/null
rm -f "$FILE_LIST"
rm -rf "$CPIO_EXTRACT_DIR"

# Use dd to overwrite CPIO archive in rpk file
2>/dev/null \
  dd \
    conv=notrunc \
    obs=1 \
    oseek="$CPIO_OFFSET" \
    of="$RPK_FILE" \
    if="$CPIO_ARCHIVE"

# Truncate the RPK file (needed in case it shrunk)
truncate --no-create --size=$((CPIO_OFFSET + $(stat --format='%s' "$CPIO_ARCHIVE"))) "$RPK_FILE"

rm "$CPIO_ARCHIVE"