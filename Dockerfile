# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Andrei Baranov (84softworks). Licensed under the Business Source License 1.1 - see LICENSE.
#
# ThunderVox Core image: Kamailio built from source by git tag, the ThunderVox config baked in.
# Only the site-local local.cfg is mounted at runtime (/etc/kamailio/local.cfg).
# Published as ghcr.io/beiroun/thundervox-core:<version> by CI on a tagged release.
#
# Module set: Kamailio's default group (every module without external dependencies: tm, sl, rr, usrloc,
# registrar, tmx, auth, auth_db, htable, dialog, nathelper, rtpengine, pike, xhttp, jsonrpcs, ctl, ...)
# plus the three that need libraries: db_postgres (libpq, the provisioning layer), http_client (libcurl,
# the push gateway) and tls (openssl, SIPS on 5061 - group mod_list_tlsdeps, never part of the default group).
# Build and install follow the INSTALL file of the Kamailio source tree:
#   make cfg include_modules="..." -> make all -> make install   (prefix /usr/local, modules in lib64/)

# Every external input is pinned (rule of 2026-10-22): the base image by exact tag and digest, the apt packages by the
# snapshot.debian.org state that image was built from (docker/apt-snapshot.sh), the source by tag and its commit.
# A bump changes all of it together and is checked first: the tag resolves, the digest is downloadable.
ARG DEBIAN_IMAGE=debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
ARG KAMAILIO_VERSION=6.0.8
# The commit the tag points at; the build refuses a tag that was moved
ARG KAMAILIO_COMMIT=73c93991e31cea52304b96e7bc5b3d1c9f3caa33

FROM ${DEBIAN_IMAGE} AS build
ARG KAMAILIO_VERSION
ARG KAMAILIO_COMMIT

COPY docker/apt-snapshot.sh /usr/local/bin/apt-snapshot
RUN apt-snapshot \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential bison flex make pkgconf git ca-certificates \
      libpq-dev libcurl4-openssl-dev libssl-dev libreadline-dev libncurses-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src
RUN git clone --depth 1 --branch "${KAMAILIO_VERSION}" https://github.com/kamailio/kamailio.git \
 && if [ "$(git -C kamailio rev-parse HEAD)" != "${KAMAILIO_COMMIT}" ]; then \
      echo "kamailio ${KAMAILIO_VERSION} is not commit ${KAMAILIO_COMMIT}" >&2; exit 1; \
    fi

WORKDIR /usr/src/kamailio
RUN make cfg include_modules="db_postgres http_client tls" \
 && make -j"$(nproc)" all \
 && make install

# The runtime stage installs exactly the libraries the binaries and modules link against
COPY docker/runtime-deps.sh /usr/local/bin/runtime-deps
RUN runtime-deps /usr/local/sbin/kamailio /usr/local/sbin/kamcmd /usr/local/lib*/kamailio/modules/*.so > /runtime-deps.txt \
 && cat /runtime-deps.txt


FROM ${DEBIAN_IMAGE}
ARG KAMAILIO_VERSION
LABEL org.opencontainers.image.title="ThunderVox Core" \
      org.opencontainers.image.description="ThunderVox SIP core: Kamailio ${KAMAILIO_VERSION} with the push-wait endpoint configuration" \
      org.opencontainers.image.source="https://github.com/beiroun/thundervox-core" \
      org.opencontainers.image.licenses="BUSL-1.1" \
      io.thundervox.kamailio.version="${KAMAILIO_VERSION}"

COPY --from=build /runtime-deps.txt /tmp/runtime-deps.txt
COPY docker/apt-snapshot.sh /tmp/apt-snapshot.sh
# netbase is no library, so the ldd-derived list never names it - yet it owns /etc/protocols, which kamailio reads
# at start (getprotobyname("tcp")); without it tcp_init() logs "could not get TCP protocol number" and leaves
# Nagle on for every TCP connection (small SIP writes to the apps wait for the ACK of the previous one).
RUN sh /tmp/apt-snapshot.sh \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      tzdata ca-certificates netbase $(cat /tmp/runtime-deps.txt) \
 && rm -rf /var/lib/apt/lists/* /tmp/runtime-deps.txt /tmp/apt-snapshot.sh

# Binaries, modules, kamcmd/kamctl and the stock share/ files (SQL schemas of kamctl are handy for reference)
COPY --from=build /usr/local/ /usr/local/

# The uid is pinned on purpose: with TVX_TLS the core reads the certificate the edge proxy obtained, and
# CertMagic hard-codes 0600 on private keys - only the same uid can read them, a shared group cannot. The
# deployment runs the edge container as this uid (see docker-compose.yml in the umbrella repository).
RUN groupadd --gid 1001 kamailio \
 && useradd --uid 1001 --gid 1001 --no-create-home --shell /usr/sbin/nologin kamailio \
 && mkdir -p /etc/kamailio /run/kamailio \
 && chown kamailio:kamailio /run/kamailio

# The ThunderVox routing logic lives in the image; it pulls /etc/kamailio/local.cfg (mounted) for site values.
# The templates of local.cfg and tls.cfg live next to the live files, in the umbrella repository
# (thundervox/deploy/local.cfg.example, tls.cfg.example) - the deployment is one directory, the image carries
# only what never changes per site.
COPY config/kamailio.cfg /etc/kamailio/

USER kamailio
# Host-networked in the compose deployment; informational (5061 only with TVX_TLS)
EXPOSE 5060/udp 5060/tcp 5061/tcp

ENTRYPOINT ["kamailio"]
# -DD: stay in the foreground (container), -E: log to stderr (kamailio.cfg sets log_stderror=yes as well)
CMD ["-DD", "-E", "-f", "/etc/kamailio/kamailio.cfg"]
