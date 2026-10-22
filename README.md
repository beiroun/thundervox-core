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
Intercom (always registered)            ThunderVox                 Phones of the flat (asleep)
        │                                    │                                  │
        │ 1. INVITE sip:10000001@tvx ───────▶│                                  │
        │                                    │ 2. app client → park (t_suspend) │
        │◀──────── 180 Ringing ──────────────│                                  │
        │                                    │ 3. wake request → server → push ▶│ phones wake up
        │                                    │                                  │
        │                                    │◀──── 4. REGISTER 10000001 ───────│ (each phone)
        │                                    │ 5. t_continue → lookup → fork    │
        │                                    │ 6. INVITE ──────────────────────▶│ (every phone rings)
        │                                    │◀──── 7. 200 OK from one phone ───│ tm cancels the rest
        │◀════════ 8. RTP/RTCP media via rtpengine ════════════════════════════▶│
```

- **1–2** — the endpoint calls an app client (a `1…` number). The call is
  **parked** at once: the INVITE transaction is suspended (`t_suspend`, tm/tmx)
  and remembered by the callee number. Whatever the location table says about
  the number is ignored — a registration an app left behind says nothing about
  the phone being awake (iOS keeps it until it expires, even after a hang-up from
  the lock screen), and every app registers again when the push arrives.
- **3** — the provisioning server is asked to wake the phones; it delivers the
  push to the operator's backend (console → Integration page).
- **4–6** — each phone of the flat REGISTERs; a **new** binding (new Call-ID)
  resumes the parked INVITE (`t_continue`) and forks it to **every** contact of
  the number, one rtpengine session per branch. A refresh of an existing
  registration does not ring the phone a second time.
- **7** — the first `200 OK` wins; tm cancels the other phones.
- **8** — `rtpengine` relays and NAT-fixes the audio/video for both legs.

The call stays parked for the **wake window** (`TVX_WAKE_WINDOW`, 90 s): a
decline of one phone (iOS answers `603` when it restarts its SIP stack
mid-ring), a dead branch or a phone that is slow to come up do not end it —
only an answer, the caller's `CANCEL` or the window itself do (`480`). While a
flat is being woken, a second call to the same number hears `486 Busy Here`.

Push-first is a **switch** (`TVX_PUSH_WAIT` in `local.cfg`), off by default:
without it the core simply rings whoever is registered (all contacts in
parallel) and answers `480 Temporarily Unavailable` to a call for an
unregistered number. That is the right mode while no push gateway is configured
on the console's Integration page — plain calls between registered devices
(Zoiper, panels) work exactly the same either way.

### What the core handles

| Case | Behaviour |
|---|---|
| REGISTER / unregister | several contacts per AoR (the owner's phone, the family's phones, a watch), NAT-safe (`received`), keepalive pings for NATed contacts, `Expires` clamped to 60–3600 s; a TCP/TLS contact leaves the table the moment its connection dies (`handle_lost_tcp` + TCP keepalive) — "online" means reachable |
| INVITE, callee online | parallel fork to every registered contact, one rtpengine session per branch (audio + video); the first `200 OK` wins, tm cancels the rest |
| INVITE, app client (`1…`) with `TVX_PUSH_WAIT` | always park + push; the devices that register after the push are rung; wake window 90 s, `486` for a second caller meanwhile |
| INVITE, callee offline | `480` |
| Call events | `started` / `answered` / `ended` posted to the provisioning server (`/internal/call-events`) whenever `TVX_CORE_TOKEN` is set — its call log and dashboard |
| CANCEL | media released, branches cancelled (a parked call too), `487` to the caller |
| BYE (either side) | media released, relayed |
| re-INVITE (hold / resume / codec or video change) | re-offer + re-answer; a rejected re-INVITE keeps the live media |
| ACK | plain 2xx ACK, late-offer ACK with SDP (answer), negative-reply ACK |
| UPDATE with SDP | early-media update |
| INFO / NOTIFY inside a dialog | relayed untouched (SIP INFO DTMF = door open; RFC2833 DTMF rides inside RTP) |
| OPTIONS to the server | `200 OK` (device keepalives / availability probes) |
| Failures and timeouts | 3xx–6xx and `408` release the media |
| Transport | UDP and TCP on 5060, SIPS on 5061 with `TVX_TLS`; one advertised public address |
| Authentication | with `TVX_PROVISIONING`: digest auth of REGISTER (`401`) and INVITE (`407`) against the accounts the provisioning server keeps in PostgreSQL (HA1 only, realm = `TVX_SIP_DOMAIN`); a number registers only itself (`403` otherwise); a blocked or deleted number fails at once. Without it the core is open (closed tests only) |
| Caller identity | never the From header — intercom firmwares put the apartment number there. With `TVX_PROVISIONING` the caller is the authenticated number; without it, the device registered from the source socket (ip:port → AoR, kept in an htable on REGISTER). An INVITE from a source that is not registered gets `403 Caller Not Registered` |
| Hygiene | scanner User-Agents dropped silently, retransmissions re-answered by tm, optional flood guard (`TVX_ANTIFLOOD`) |

---

## Components

| Path | Role |
|---|---|
| `config/kamailio.cfg` | SIP signaling, registrar, NAT detection, push-wait routing |
| *(umbrella)* `thundervox/deploy/local.cfg.example` | Template for the site-local values (SIP domain, public IP, server token) and the feature switches - next to the live `local.cfg` it is copied to |
| *(umbrella)* `thundervox/deploy/tls.cfg.example` | Template for the TLS profiles read with `TVX_TLS` (certificate and key paths, TLS method) |
| `ci/fixture.cfg` | Fake `local.cfg` for the config check in CI (`kamailio -c` with the switches off and on); not a template |
| `Dockerfile` | Core image: Kamailio **6.0.8 built from source** (default module group + `db_postgres`, `http_client`, `tls`), `kamailio.cfg` baked in, non-root with a pinned uid 1001 (so it can read the certificate the edge proxy obtained) |
| `rtpengine/Dockerfile`, `rtpengine/entrypoint.sh` | Media image: rtpengine **mr26.2.1.2 built from source**, userspace forwarding, every parameter an explicit flag from `TVX_*` environment |
| `docker/runtime-deps.sh` | Build helper: derives the runtime Debian packages from what the binaries actually link against |
| `docker/apt-snapshot.sh` | Build helper: points apt at the snapshot.debian.org state the pinned base image was built from, so the packages are pinned with the image (see "Pinned inputs") |
| `.github/workflows/` | `ci.yml` builds both images and runs `kamailio -c` on every push to `release`; `release.yml` publishes `ghcr.io/beiroun/thundervox-core` and `…/thundervox-rtpengine` on a `vX.Y.Z` tag |
| *(external)* provisioning server | `thundervox-server`: the core asks it on loopback to wake a sleeping callee; the server delivers the push to the operator's backend configured on the console's Integration page — **not** in this repo |

**Pinned inputs.** Nothing in a build floats (rule of 2026-10-22): the Dockerfile frontend, the Debian base
(`trixie-<date>-slim` + digest), the apt packages (the base image's own snapshot.debian.org state, via
`docker/apt-snapshot.sh`; the build stops if the image does not name one), the Kamailio and rtpengine sources
(tag + the commit it must point at), the GitHub Actions (commit SHA), buildx and BuildKit, the runner
(`ubuntu-24.04`). A bump changes a pin deliberately, after checking that the new tag resolves and downloads.

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
`local.cfg` is created from `deploy/local.cfg.example` of the umbrella
repository (template and live file side by side in the deployment directory)
and mounted into the core container at `/etc/kamailio/local.cfg`; `config/` in
this repository is what the image bakes in, not a deployment.

`local.cfg` is pulled into `kamailio.cfg` by `include_file` and defines:

| Constant | Meaning |
|---|---|
| `TVX_SIP_DOMAIN` | DNS name of the server (preferred). Devices register to it and dial through it; when set, the core advertises it in Via/Record-Route and treats it as its own domain. |
| `TVX_PUBLIC_IP` | Server public IP. Advertised instead of the domain when `TVX_SIP_DOMAIN` is absent; otherwise only accepted as "myself" for devices that dial by raw IP. Must equal the address rtpengine advertises (`TVX_PUBLIC_IP` in the deployment `.env`). **At least one of the two must be set.** |
| `TVX_CORE_TOKEN` | Token sent as `X-CORE-TOKEN` to the provisioning server's internal API; must equal `TVX_CORE_TOKEN` in the deployment `.env`. When set, the core reports call events to the server; `TVX_PUSH_WAIT` requires it. Leave it out only when there is no server. |
| `TVX_SERVER_URL` | Base URL of the provisioning server's API, default `http://127.0.0.1:8080/api/v1` (used with `TVX_CORE_TOKEN`). |
| `TVX_DB_URL` | `postgres://tvx_sip:<password>@127.0.0.1:5432/thundervox` — the provisioning database, role `tvx_sip` (created by the server's migration, password = `TVX_SIP_DB_PASSWORD` of the deployment `.env`). Used only with `TVX_PROVISIONING`. |

With `TVX_TLS` a second file, `tls.cfg`, is mounted next to `local.cfg` (template
`deploy/tls.cfg.example` in the umbrella repository). It names the certificate and the
key, which the deployment's edge proxy obtains and renews; `kamcmd tls.reload`
re-reads it, so a renewal needs no restart and keeps the registrations.

Switches — `#!define NAME` lines in `local.cfg`, all **off** when absent:

| Switch | Effect |
|---|---|
| `TVX_PROVISIONING` | Accounts and registrations from the provisioning server: `auth_db` checks REGISTER and INVITE against its `subscriber` table, `usrloc` writes registrations through to its `location` table (they survive a restart, the console shows who is online). Needs `TVX_SIP_DOMAIN` (the digest realm — it must equal the realm the server hashes with, `TVX_SIP_HOST` of the `.env`) and `TVX_DB_URL`; without them the config check fails with `TVX_PROVISIONING_NEEDS_…` tokens. Switch it on only after every device got its password. |
| `TVX_PUSH_WAIT` | App clients (`1…`) are push-first: their INVITEs are parked for the wake window and the provisioning server is asked to wake the phones (it delivers the push to the operator's backend); the devices that register after the push are rung in parallel. Needs `TVX_CORE_TOKEN`. Off: a registered callee is simply rung, an offline one gets `480`. |
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
  ghcr.io/beiroun/thundervox-core:0.10.0 -c -f /etc/kamailio/kamailio.cfg
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

To exercise the **push-first** path, define `TVX_PUSH_WAIT` in `local.cfg`,
restart kamailio, and call a `1…` number (an app client): the caller hears
ringing and a wake request reaches the server whether or not a softphone is
registered under that number. Then make a softphone register **anew** (toggle
the account off and on — a refresh with the same Call-ID does not count) — the
parked call connects. Two softphones on the same number ring together and the
one that answers ends the ringing of the other. A decline (`603`) from the only
ringing softphone keeps the caller ringing until the window closes or another
softphone registers.

---

## Known limitations / TODO

- **Synchronous requests to the server.** `route[PUSH]` and the call events
  call the provisioning server synchronously; the server answers on loopback
  before any network work and delivers the push to the operator's backend
  itself, so the worst case is the server being down (`connection_timeout`,
  2 s per request), not a slow operator backend.
- **One parked call per number.** While a flat is being woken, a second call to
  the same number gets `486 Busy Here` instead of a second park.
- **Losing branches keep their media legs.** The rtpengine sessions of the
  phones that did not answer live until the call ends (the final delete drops
  the whole call); a few relay ports per unanswered phone for the duration of
  the call.
- **Open without `TVX_PROVISIONING`.** With the switch off any host may register
  any number — closed tests only (calls are still accepted only from registered
  sources). `TVX_TLS` protects the channel, not the identity.
- **Blocking does not evict.** A number blocked or deleted in the console fails
  authentication at once, but its current registration stays until it expires
  (it can still be called meanwhile). Eviction over the core's RPC is a next step.
- **The database is on the SIP path.** With `TVX_PROVISIONING` every REGISTER
  and INVITE reads PostgreSQL; a database outage locks every device out
  (logged as `auth ERROR rc=-1`).
- **Calls are not persisted.** `dialog` is in-memory: live calls are lost on a
  restart (registrations survive with `TVX_PROVISIONING`).
- **Single node.** One Kamailio + one rtpengine. Horizontal scale (dispatcher to a
  media pool, HA registrar) is the v1 target.
- **Dead UDP contacts are discovered late.** A NATed UDP device that vanished
  without unregistering stays in the table until its registration expires
  (`max_expires`, 1 h) or a call to it times out. TCP/TLS contacts are dropped
  with their connection (`handle_lost_tcp`); usrloc keepalive with OPTIONS for
  UDP contacts is a v1 item.

---

## Roadmap

- **v0.6** — Docker Compose on a single host, upstream images.
  Stable calls between registered devices, caller identity by registration,
  push-wait as a switch.
- **v0.7** — the same core on **own images built from source** (Kamailio
  6.0.8, rtpengine mr26.2.1.2), published to GHCR by CI; the deployment moves
  to the umbrella repository, the host keeps only compose + config.
- **v0.9** — SIP over TLS (`TVX_TLS`) with the certificate of the edge proxy.
- **v0.10** — provisioning: digest authentication from PostgreSQL
  (`TVX_PROVISIONING`, `auth_db`), registrations persisted (`usrloc`
  write-through).
- **v0.11** — the wake request goes through the provisioning server (the
  push gateway lives on the console's Integration page).
- **v0.12** — several devices per number with parallel forking and per-branch
  media, push-first app clients with a wake window (`t_suspend`/`t_continue`
  instead of tsilo), TCP liveness (`handle_lost_tcp`), call events to the
  server *(current)*. Next: JSON-RPC for the server (evict a registration, end
  a call).
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
