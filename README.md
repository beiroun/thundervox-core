# ThunderVox Core

**The REAL SIP server** — a thin, scalable SIP endpoint platform for physical
devices (intercoms, elevators, gates, SOS points) that place calls to mobile apps
which are *not* continuously registered.

This repository is the **signaling and media core** of the
[ThunderVox](https://github.com/beiroun/thundervox) platform, built on
**Kamailio** (signaling + registrar) and **rtpengine** (media + NAT). The
provisioning server and the web console live in their own repositories
([`thundervox-server`](https://github.com/beiroun/thundervox-server),
[`thundervox-web`](https://github.com/beiroun/thundervox-web)); the umbrella
repository holds the project charter and the deployment of the whole system.

---

## The core idea: push-wait

Mobile apps cannot hold a permanent SIP registration — iOS kills background
sockets, and keeping 100k+ apps registered would be pointless load. So the callee
is normally *offline* when an endpoint calls it. ThunderVox bridges that gap by
**parking** the call and **waking** the device with a push:

```
Intercom (always registered)            ThunderVox               Mobile app (asleep)
        │                                    │                            │
        │ 1. INVITE sip:1001@tvx ───────────▶│                            │
        │                                    │ 2. lookup(1001) → offline  │
        │                                    │ 3. ts_store()  (park call) │
        │◀──────── 180 Ringing ──────────────│                            │
        │                                    │ 4. push (HTTP) ───────────▶│ wakes up
        │                                    │                            │
        │                                    │◀──── 5. REGISTER 1001 ─────│
        │                                    │ 6. ts_append() → resume    │
        │                                    │ 7. INVITE ────────────────▶│
        │◀════════ 8. RTP/RTCP media via rtpengine ══════════════════════▶│
```

- **1–3** — the endpoint calls; the app is not in the location table, so the INVITE
  transaction is **parked** (`tsilo` module), keyed by the callee AoR.
- **4** — a push notification wakes the device.
- **5–7** — the app REGISTERs; `tsilo` **resumes** the parked INVITE and routes it to
  the freshly-registered contact.
- **8** — `rtpengine` relays and NAT-fixes the audio/video for both legs.

If the callee is **already registered** (e.g. a Zoiper softphone during testing),
steps 3–6 are skipped and the INVITE is relayed immediately.

Push-wait is a **switch** (`TVX_PUSH_WAIT` in `local.cfg`), off by default:
without it an offline callee gets `480 Temporarily Unavailable` at once. That is
the right mode while the push gateway is not deployed — plain calls between
registered devices work exactly the same either way.

### What the core handles

| Case | Behaviour |
|---|---|
| REGISTER / unregister | one contact per AoR (latest registration wins), NAT-safe (`received`), keepalive pings for NATed contacts, `Expires` clamped to 60–3600 s |
| INVITE, callee online | SDP anchored on rtpengine (audio + video), relayed to the registered contact |
| INVITE, callee offline | `480` — or park + push with `TVX_PUSH_WAIT` |
| CANCEL | media released, branch cancelled, `487` to the caller |
| BYE (either side) | media released, relayed |
| re-INVITE (hold / resume / codec or video change) | re-offer + re-answer; a rejected re-INVITE keeps the live media |
| ACK | plain 2xx ACK, late-offer ACK with SDP (answer), negative-reply ACK |
| UPDATE with SDP | early-media update |
| INFO / NOTIFY inside a dialog | relayed untouched (SIP INFO DTMF = door open; RFC2833 DTMF rides inside RTP) |
| OPTIONS to the server | `200 OK` (device keepalives / availability probes) |
| Failures and timeouts | 3xx–6xx and `408` release the media |
| Transport | UDP and TCP on 5060, SIPS on 5061 with `TVX_TLS`; one advertised public address |
| Caller identity | the calling device is the one registered from the source socket (ip:port → AoR, kept in an htable on REGISTER), never the From header — intercom firmwares put the apartment number there. An INVITE from a source that never registered gets `403 Caller Not Registered` |
| Hygiene | scanner User-Agents dropped silently, retransmissions re-answered by tm, optional flood guard (`TVX_ANTIFLOOD`) |

---

## Components

| Path | Role |
|---|---|
| `config/kamailio.cfg` | SIP signaling, registrar, NAT detection, push-wait routing |
| `config/local.cfg.example` | Template for the site-local values (SIP domain, public IP, push URL, service token) and the feature switches; shipped inside the image at `/etc/kamailio/local.cfg.example` |
| `config/tls.cfg.example` | Template for the TLS profiles read with `TVX_TLS` (certificate and key paths, TLS method); shipped inside the image at `/etc/kamailio/tls.cfg.example` |
| `Dockerfile` | Core image: Kamailio **6.0.8 built from source** (default module group + `db_postgres`, `http_client`, `tls`), `kamailio.cfg` baked in, non-root with a pinned uid 1001 (so it can read the certificate the edge proxy obtained) |
| `rtpengine/Dockerfile`, `rtpengine/entrypoint.sh` | Media image: rtpengine **mr26.2.1.2 built from source**, userspace forwarding, every parameter an explicit flag from `TVX_*` environment |
| `docker/runtime-deps.sh` | Build helper: derives the runtime Debian packages from what the binaries actually link against |
| `.github/workflows/` | `ci.yml` builds both images and runs `kamailio -c` on every push to `release`; `release.yml` publishes `ghcr.io/beiroun/thundervox-core` and `…/thundervox-rtpengine` on a `vX.Y.Z` tag |
| *(external)* push gateway | HTTP endpoint that delivers APNs/FCM pushes — **not** in this repo |

**NAT strategy:** the *received* method for registered devices
(`fix_nated_register` + `received_avp`) and the *alias* method for the other
in-dialog party (`set_contact_alias` / `handle_ruri_alias`). Media is always
anchored on `rtpengine`, so RTP never needs a direct path between the two UAs.

---

## Configure and run

The core is **deployed from the umbrella repository**
[`thundervox`](https://github.com/beiroun/thundervox) (`deploy/docker-compose.yml`,
`.env`, `local.cfg`, runbook) — this repository only builds the images and holds
the configuration they bake in. Site-local values are not committed anywhere:
`local.cfg` is created from the template that ships inside the image and
mounted into the core container at `/etc/kamailio/local.cfg`; `config/` in
this repository is what the image bakes in, not a deployment:

```bash
docker run --rm --entrypoint cat ghcr.io/beiroun/thundervox-core:0.7.0 /etc/kamailio/local.cfg.example > local.cfg
```

`local.cfg` is pulled into `kamailio.cfg` by `include_file` and defines:

| Constant | Meaning |
|---|---|
| `TVX_SIP_DOMAIN` | DNS name of the server (preferred). Devices register to it and dial through it; when set, the core advertises it in Via/Record-Route and treats it as its own domain. |
| `TVX_PUBLIC_IP` | Server public IP. Advertised instead of the domain when `TVX_SIP_DOMAIN` is absent; otherwise only accepted as "myself" for devices that dial by raw IP. Must equal the address rtpengine advertises (`TVX_PUBLIC_IP` in the deployment `.env`). **At least one of the two must be set.** |
| `TVX_PUSH_URL` | Push gateway HTTP endpoint (used only with `TVX_PUSH_WAIT`). |
| `TVX_PUSH_TOKEN` | Service token sent as `X-SERVICE-TOKEN`; must equal `SERVICE_TV_SIP_TOKEN` on the backend. |

With `TVX_TLS` a second file, `tls.cfg`, is mounted next to `local.cfg` (template
`/etc/kamailio/tls.cfg.example` in the image). It names the certificate and the
key, which the deployment's edge proxy obtains and renews; `kamcmd tls.reload`
re-reads it, so a renewal needs no restart and keeps the registrations.

Switches — `#!define NAME` lines in `local.cfg`, all **off** when absent:

| Switch | Effect |
|---|---|
| `TVX_PUSH_WAIT` | Park INVITEs for offline callees and wake the device by push. Off: offline callee gets `480`. |
| `TVX_ANTIFLOOD` | pike request-rate guard: more than 32 requests / 2 s from one IP are dropped. |
| `TVX_TLS` | Accept SIPS on 5061 as well (plain 5060 stays open). Needs `TVX_SIP_DOMAIN` — a certificate is issued for a name, never for an IP — and a filled-in `tls.cfg`. Without the domain the config check fails with the token `TVX_TLS_NEEDS_TVX_SIP_DOMAIN_A_CERTIFICATE_IS_ISSUED_FOR_A_NAME_NOT_AN_IP`. |

A `local.cfg` with neither `TVX_SIP_DOMAIN` nor `TVX_PUBLIC_IP` fails the config
check with the token `NEITHER_TVX_SIP_DOMAIN_NOR_TVX_PUBLIC_IP_IS_DEFINED_IN_LOCAL_CFG`.
Non-secret tunables stay in `kamailio.cfg` itself: `TVX_RTP_FLAGS` (rtpengine
per-leg flags, plain RTP/AVP with ICE stripped), `TVX_RTPENGINE_SOCK` and the
tm timers (`fr_timer` 30 s, `fr_inv_timer` 120 s).

Config check against the image, before touching a running core:

```bash
docker run --rm -v "$PWD/local.cfg:/etc/kamailio/local.cfg:ro" \
  ghcr.io/beiroun/thundervox-core:0.7.0 -c -f /etc/kamailio/kamailio.cfg
```

Every kamailio log line is prefixed with `{<1=request|2=reply> <CSeq> <Call-ID>}`,
so one call can be followed with a single `grep <Call-ID>`.

**Images.** `ghcr.io/beiroun/thundervox-core` (Kamailio 6.0.8 from source,
`kamailio.cfg` inside, only `local.cfg` mounted) and
`ghcr.io/beiroun/thundervox-rtpengine` (rtpengine mr26.2.1.2 from source). Both
are built on `debian:trixie-slim`, run as non-root users, and carry the version
of the git tag they were built from — the two always ship together. Nothing at
runtime depends on third-party packages or images.

The rtpengine image takes its parameters from the environment
(`TVX_PUBLIC_IP`, optional `TVX_LOCAL_IP` for 1:1 NAT hosts, `TVX_RTP_NG_PORT`,
`TVX_RTP_PORT_MIN`/`MAX`, `TVX_RTP_LOG_LEVEL`) and turns them into explicit
rtpengine flags; the ng control socket listens on `127.0.0.1` only, matching the
core's `TVX_RTPENGINE_SOCK`.

Building locally (not needed on the server — CI publishes the images):

```bash
docker build -t thundervox-core:dev .
docker build -t thundervox-rtpengine:dev -f rtpengine/Dockerfile .
```

Live state via `kamcmd` (ctl socket inside the container):

```bash
docker exec thundervox-core kamcmd -s unix:/tmp/kamailio_ctl ul.dump          # registrations
docker exec thundervox-core kamcmd -s unix:/tmp/kamailio_ctl dlg.list         # live calls
docker exec thundervox-core kamcmd -s unix:/tmp/kamailio_ctl dlg.stats_active # call counters
docker exec thundervox-core kamcmd -s unix:/tmp/kamailio_ctl tm.stats         # transactions
docker exec thundervox-core kamcmd -s unix:/tmp/kamailio_ctl rtpengine.show all
```

**Firewall — open to the internet:**

| Port | Proto | Purpose |
|---|---|---|
| 5060 | UDP + TCP | SIP signaling |
| 5061 | TCP | SIP over TLS (SIPS), only with `TVX_TLS` |
| 29000–30000 | UDP | RTP/RTCP media (rtpengine range; narrow test pool, widen for production) |

---

## Test with Zoiper (softphone stands in for the mobile app)

1. Register a Zoiper account against `TVX_PUBLIC_IP:5060` as user `1001`.
   Because it stays registered, it exercises the **online** path (no push).
2. Point an intercom/second softphone at the server and dial `sip:1001@TVX_PUBLIC_IP`.
3. Expect two-way audio (rtpengine relays it). Watch `[TVX]` logs for the routing
   decision (`callee ONLINE` vs `callee OFFLINE, parking + push`).

With push-wait off (default) a call to an unregistered number is answered with
`480` immediately — the caller's device must handle that cleanly. A call *from*
a softphone that is not registered itself is answered with `403 Caller Not
Registered`: register first, then dial.

To exercise the **push-wait** path, define `TVX_PUSH_WAIT` in `local.cfg`,
restart kamailio, let the callee go **unregistered**, place the call (caller
hears ringing, a push fires), then REGISTER the callee — the parked call connects.

---

## Known limitations / TODO

- **Synchronous push.** `route[PUSH]` calls the gateway synchronously and can block
  a SIP worker for up to `connection_timeout` (2s). Production: async push-gateway
  microservice, fire-and-forget.
- **No authentication yet.** Any host may register any number — closed tests
  only. Calls are accepted only from registered sources (`403` otherwise), which
  keeps fraud probes out but does not stop a stranger from registering a number
  they do not own. Digest authentication arrives with the provisioning layer
  (`TVX_PROVISIONING`: `auth_db` against PostgreSQL, passwords issued by the
  server) in v0.8. Transport encryption is available now (`TVX_TLS`), but it
  protects the channel, not the identity: without digest auth a stranger can
  still register over TLS.
- **One contact per AoR.** A second device registering the same number replaces
  the first. Multi-device users need parallel forking with per-branch rtpengine
  sessions (`via-branch` in a branch route) — v1.
- **No persistence.** `usrloc` and `dialog` are in-memory; registrations and
  call state are lost on restart. Add DB-mode + Redis for HA.
- **Single node.** One Kamailio + one rtpengine. Horizontal scale (dispatcher to a
  media pool, HA registrar) is the v1 target.
- **Dead contacts are discovered late.** A NATed device that vanished without
  unregistering is only noticed when a call to it times out (`fr_timer` 30 s).
  usrloc keepalive with OPTIONS and contact purging is a v1 item.

---

## Roadmap

- **v0.6** — Docker Compose on a single host, upstream images.
  Stable calls between registered devices, caller identity by registration,
  push-wait as a switch.
- **v0.7** — the same core on **own images built from source** (Kamailio
  6.0.8, rtpengine mr26.2.1.2), published to GHCR by CI; the deployment moves
  to the umbrella repository, the host keeps only compose + config *(current)*.
- **v0.8** — provisioning layer: digest authentication from PostgreSQL
  (`TVX_PROVISIONING`, `auth_db`), registrations persisted (`usrloc`
  write-through), JSON-RPC for the server.
- **v1** — Kubernetes: stateless Kamailio edge (HA), rtpengine media pool behind
  `dispatcher`, Redis-backed presence, async push service.

---

## License

**Business Source License 1.1** — see [`LICENSE`](LICENSE). Non-production
use is free; production use beyond the Additional Use Grant requires a
commercial license from the Licensor. The license applies to the ThunderVox
code in this repository (configuration, build files, documentation).
Kamailio and rtpengine remain under their own licenses (GPL); see `NOTICE`
in the umbrella repository.
