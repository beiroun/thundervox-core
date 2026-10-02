#!/bin/sh
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Andrei Baranov (84softworks). Licensed under the Business Source License 1.1 - see LICENSE.
#
# Prints the Debian packages that own the shared libraries the given ELF files link against, one per line.
# Used at the end of a build stage so the runtime stage installs exactly what the binaries need, without a
# hand-maintained list that breaks on every Debian library rename (libcurl4 -> libcurl4t64 and friends).
# Libraries that belong to no package (our own, under /usr/local) are skipped: they are copied with the binaries.
set -eu

for file in "$@"; do
    ldd "$file" 2>/dev/null | awk '/=> \// { print $3 }'
done | sort -u | while read -r library; do
    # dpkg knows the real file; resolve symlinks (and the /lib -> /usr/lib merge) before asking it
    resolved="$(readlink -f "$library")"
    dpkg -S "$resolved" 2>/dev/null || dpkg -S "$library" 2>/dev/null || true
done | cut -d: -f1 | sort -u
