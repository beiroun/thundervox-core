#!/bin/sh
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Andrei Baranov (84softworks). Licensed under the Business Source License 1.1 - see LICENSE.
#
# Points apt at the snapshot.debian.org state the base image itself was built from, so the packages installed on
# top of a pinned debian image are pinned too: the same digest always gets the same package versions, and they
# stay downloadable after the live mirror has moved on. The official debian images name their snapshot in a
# comment right above every URIs line of debian.sources; that comment becomes the URIs line.
#
# Fails the build when the base image does not carry the snapshot comments: apt would silently fall back to the
# live mirror otherwise.
set -eu

sources=/etc/apt/sources.list.d/debian.sources

awk '
  /^# http:\/\/snapshot\.debian\.org\/archive\// { snapshot = substr($0, 3); next }
  /^URIs: / && snapshot != "" { print "URIs: " snapshot; snapshot = ""; next }
  { print }
' "$sources" > "$sources.pinned"

if grep -q '^URIs: http://deb.debian.org' "$sources.pinned" || ! grep -q '^URIs: http://snapshot.debian.org/' "$sources.pinned"; then
  echo "apt-snapshot: $sources has no snapshot comment for every URIs line - refusing the live mirror" >&2
  cat "$sources" >&2
  exit 1
fi
mv "$sources.pinned" "$sources"

# A snapshot's Release files are past their Valid-Until by design (trixie-security sets one a week ahead)
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99snapshot
grep '^URIs:' "$sources"
