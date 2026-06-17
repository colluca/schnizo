#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

SRC="/scratch/sem26f5/cache"
DST_BASE="/scratch/sem26f5/backup"

mkdir -p "$DST_BASE"

i=0
while [ -e "$DST_BASE/V$i" ]; do
  i=$((i + 1))
done

DST="$DST_BASE/V$i"
mkdir -p "$DST"

echo "Moving immediate directories from:"
echo "  $SRC"
echo "to:"
echo "  $DST"
echo ""

shopt -s nullglob

for dir in "$SRC"/*/; do
  name="$(basename "$dir")"
  echo "Moving $name ..."
  mv "$dir" "$DST/"
done

echo ""
echo "Done. Moved cache directories to $DST"