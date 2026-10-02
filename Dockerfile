# syntax=docker/dockerfile:1
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Andrei Baranov (84softworks). Licensed under the Business Source License 1.1 - see LICENSE.
#
# ThunderVox Core image: Kamailio built from source by git tag, the ThunderVox config baked in.
# Only the site-local local.cfg is mounted at runtime (/etc/kamailio/local.cfg).
# Published as ghcr.io/beiroun/thundervox-core:<version> by CI on a tagged release.
#
# Module set: Kamailio's default group (every module without external dependencies: tm, sl, rr, usrloc,
# registrar, auth, auth_db, htable, dialog, nathelper, rtpengine, tsilo, pike, xhttp, jsonrpcs, ctl, ...)
# plus the two that need libraries: db_postgres (libpq, the provisioning layer) and http_client (libcurl,
# the push gateway). Build and install follow the INSTALL file of the Kamailio source tree:
#   make cfg include_modules="..." -> make all -> make install   (prefix /usr/local, modules in lib64/)

ARG KAMAILIO_VERSION=6.0.8

FROM debian:trixie-slim AS build
ARG KAMAILIO_VERSION

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential bison flex make pkgconf git ca-certificates \
      libpq-dev libcurl4-openssl-dev libreadline-dev libncurses-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src
RUN git clone --depth 1 --branch "${KAMAILIO_VERSION}" https://github.com/kamailio/kamailio.git

WORKDIR /usr/src/kamailio
RUN make cfg include_modules="db_postgres http_client" \
 && make -j"$(nproc)" all \
 && make install

# The runtime stage installs exactly the libraries the binaries and modules link against
COPY docker/runtime-deps.sh /usr/local/bin/runtime-deps
RUN runtime-deps /usr/local/sbin/kamailio /usr/local/sbin/kamcmd /usr/local/lib*/kamailio/modules/*.so > /runtime-deps.txt \
 && cat /runtime-deps.txt


FROM debian:trixie-slim
ARG KAMAILIO_VERSION
LABEL org.opencontainers.image.title="ThunderVox Core" \
      org.opencontainers.image.description="ThunderVox SIP core: Kamailio ${KAMAILIO_VERSION} with the push-wait endpoint configuration" \
      org.opencontainers.image.source="https://github.com/beiroun/thundervox-core" \
      org.opencontainers.image.licenses="BUSL-1.1" \
      io.thundervox.kamailio.version="${KAMAILIO_VERSION}"

COPY --from=build /runtime-deps.txt /tmp/runtime-deps.txt
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      tzdata ca-certificates $(cat /tmp/runtime-deps.txt) \
 && rm -rf /var/lib/apt/lists/* /tmp/runtime-deps.txt

# Binaries, modules, kamcmd/kamctl and the stock share/ files (SQL schemas of kamctl are handy for reference)
COPY --from=build /usr/local/ /usr/local/

RUN groupadd --system kamailio \
 && useradd --system --gid kamailio --no-create-home --shell /usr/sbin/nologin kamailio \
 && mkdir -p /etc/kamailio /run/kamailio \
 && chown kamailio:kamailio /run/kamailio

# The ThunderVox routing logic lives in the image; it pulls /etc/kamailio/local.cfg (mounted) for site values
COPY deployment/configuration/kamailio.cfg /etc/kamailio/kamailio.cfg

USER kamailio
# Host-networked in the compose deployment; informational
EXPOSE 5060/udp 5060/tcp

ENTRYPOINT ["kamailio"]
# -DD: stay in the foreground (container), -E: log to stderr (kamailio.cfg sets log_stderror=yes as well)
CMD ["-DD", "-E", "-f", "/etc/kamailio/kamailio.cfg"]
