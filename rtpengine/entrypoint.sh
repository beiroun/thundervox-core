#!/bin/sh
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Andrei Baranov (84softworks). Licensed under the Business Source License 1.1 - see LICENSE.
#
# Starts rtpengine with every parameter spelled out as a command-line flag (names from the rtpengine manual,
# docs/rtpengine.md at the pinned tag). The environment is the only input:
#
#   TVX_PUBLIC_IP      required  address the media is advertised on in SDP (the server's public IP)
#   TVX_LOCAL_IP       optional  address of the local interface when it differs from the public one
#                                (1:1 NAT at the hoster) -> --interface=LOCAL!PUBLIC
#   TVX_RTP_NG_PORT    4444      ng control port on 127.0.0.1, the core's rtpengine_sock points here
#   TVX_RTP_PORT_MIN   29000     media port range (open it in the firewall, UDP)
#   TVX_RTP_PORT_MAX   30000
#   TVX_RTP_LOG_LEVEL  6         syslog level, 6 = info, 7 = debug
#
# Anything passed to the container after the image name is appended as extra rtpengine flags.
set -eu

: "${TVX_PUBLIC_IP:?TVX_PUBLIC_IP is required: the public address media is advertised on}"

ng_port="${TVX_RTP_NG_PORT:-4444}"
port_min="${TVX_RTP_PORT_MIN:-29000}"
port_max="${TVX_RTP_PORT_MAX:-30000}"
log_level="${TVX_RTP_LOG_LEVEL:-6}"

if [ -n "${TVX_LOCAL_IP:-}" ]; then
    interface="${TVX_LOCAL_IP}!${TVX_PUBLIC_IP}"
else
    interface="${TVX_PUBLIC_IP}"
fi

echo "thundervox-rtpengine: interface=${interface} listen-ng=127.0.0.1:${ng_port} ports=${port_min}-${port_max} log-level=${log_level}"

# --table=-1: userspace forwarding only, never touch the kernel module.
# --listen-ng on loopback: the control protocol is for the core on the same host, not for the internet.
exec rtpengine \
    --interface="${interface}" \
    --listen-ng="127.0.0.1:${ng_port}" \
    --port-min="${port_min}" \
    --port-max="${port_max}" \
    --log-level="${log_level}" \
    --table=-1 \
    --foreground \
    --log-stderr \
    "$@"
