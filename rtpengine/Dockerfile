# syntax=docker/dockerfile:1
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Andrei Baranov (84softworks). Licensed under the Business Source License 1.1 - see LICENSE.
#
# ThunderVox media relay: Sipwise rtpengine built from source by git tag, userspace forwarding
# (no kernel module: the host runs other things, and the current call volume does not need it).
# Build context is the repository root (docker/runtime-deps.sh is shared with the core image):
#   docker build -f rtpengine/Dockerfile .
# Published as ghcr.io/beiroun/thundervox-rtpengine:<version> by CI on a tagged release.
#
# Build recipe and dependency list follow the Dockerfile shipped in the rtpengine repository at this tag
# (debian:trixie-slim, `make rtpengine` in daemon/, transcoding on). The recording daemon is not built.

ARG RTPENGINE_VERSION=mr26.2.1.2

FROM debian:trixie-slim AS build
ARG RTPENGINE_VERSION

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential ca-certificates git gperf make pkgconf \
      default-libmysqlclient-dev \
      libavcodec-dev libavfilter-dev libavformat-dev libavutil-dev libswresample-dev \
      libbcg729-dev libcurl4-openssl-dev libevent-dev libglib2.0-dev libhiredis-dev libiptc-dev \
      libjson-glib-dev libjwt-dev libncursesw5-dev libopus-dev libpcap-dev libpcre2-dev libspandsp-dev \
      libssl-dev libwebsockets-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src
RUN git clone --depth 1 --branch "${RTPENGINE_VERSION}" https://github.com/sipwise/rtpengine.git

WORKDIR /usr/src/rtpengine/daemon
RUN make -j"$(nproc)" rtpengine \
 && strip -o /usr/local/bin/rtpengine rtpengine

COPY docker/runtime-deps.sh /usr/local/bin/runtime-deps
RUN runtime-deps /usr/local/bin/rtpengine > /runtime-deps.txt \
 && cat /runtime-deps.txt


FROM debian:trixie-slim
ARG RTPENGINE_VERSION
LABEL org.opencontainers.image.title="ThunderVox rtpengine" \
      org.opencontainers.image.description="ThunderVox media relay: Sipwise rtpengine ${RTPENGINE_VERSION}, userspace forwarding" \
      org.opencontainers.image.source="https://github.com/beiroun/thundervox-core" \
      org.opencontainers.image.licenses="BUSL-1.1" \
      io.thundervox.rtpengine.version="${RTPENGINE_VERSION}"

COPY --from=build /runtime-deps.txt /tmp/runtime-deps.txt
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      tzdata ca-certificates $(cat /tmp/runtime-deps.txt) \
 && rm -rf /var/lib/apt/lists/* /tmp/runtime-deps.txt

COPY --from=build /usr/local/bin/rtpengine /usr/local/bin/rtpengine
COPY rtpengine/entrypoint.sh /usr/local/bin/thundervox-rtpengine

RUN groupadd --system rtpengine \
 && useradd --system --gid rtpengine --no-create-home --shell /usr/sbin/nologin rtpengine

USER rtpengine
# Host-networked in the compose deployment; the media range is configured by TVX_RTP_PORT_MIN/MAX
EXPOSE 29000-30000/udp

ENTRYPOINT ["thundervox-rtpengine"]
