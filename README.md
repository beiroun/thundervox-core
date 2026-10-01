# ThunderVox

**The REAL SIP server** — a thin, scalable SIP endpoint platform for physical
devices (intercoms, elevators, gates, SOS points) that place calls to mobile apps
which are *not* continuously registered.

Built on **Kamailio** (signaling + registrar) and **rtpengine** (media + NAT).

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
| Transport | UDP and TCP on 5060, one advertised public address |
| Hygiene | scanner User-Agents dropped silently, retransmissions re-answered by tm, optional flood guard (`TVX_ANTIFLOOD`), optional digest auth (`TVX_AUTH`) |

---

## Components

| Path | Role |
|---|---|
| `deployment/configuration/kamailio.cfg` | SIP signaling, registrar, NAT detection, push-wait routing |
| `deployment/configuration/local.cfg.example` | Template for the site-local values (public IP, push URL, service token) and the feature switches |
| `deployment/configuration/users.cfg.example` | Template for SIP credentials (only read with `TVX_AUTH`) |
| `deployment/docker-compose.yml` | Kamailio + rtpengine, host-networked |
| `deployment/.env.example` | Template for the host address docker compose feeds to rtpengine |
| *(external)* push gateway | HTTP endpoint that delivers APNs/FCM pushes — **not** in this repo |

**NAT strategy:** the *received* method for registered devices
(`fix_nated_register` + `received_avp`) and the *alias* method for the other
in-dialog party (`set_contact_alias` / `handle_ruri_alias`). Media is always
anchored on `rtpengine`, so RTP never needs a direct path between the two UAs.

---

## Configure

Site-local values are **not** in this repository — no address, endpoint or token
is committed. Create both files from their templates:

```bash
cd deployment
cp configuration/local.cfg.example configuration/local.cfg
cp .env.example .env
```

`configuration/local.cfg` is pulled into `kamailio.cfg` by `include_file` and
defines:

| Constant | Meaning |
|---|---|
| `TVX_SIP_DOMAIN` | DNS name of the server (preferred). Devices register to it and dial through it; when set, the core advertises it in Via/Record-Route and treats it as its own domain. |
| `TVX_PUBLIC_IP` | Server public IP. Advertised instead of the domain when `TVX_SIP_DOMAIN` is absent; otherwise only accepted as "myself" for devices that dial by raw IP. Must equal the value in `.env` (rtpengine). **At least one of the two must be set.** |
| `TVX_PUSH_URL` | Push gateway HTTP endpoint (used only with `TVX_PUSH_WAIT`). |
| `TVX_PUSH_TOKEN` | Service token sent as `X-SERVICE-TOKEN`; must equal `SERVICE_TV_SIP_TOKEN` on the backend. |

Switches — `#!define NAME` lines in `local.cfg`, all **off** when absent:

| Switch | Effect |
|---|---|
| `TVX_PUSH_WAIT` | Park INVITEs for offline callees and wake the device by push. Off: offline callee gets `480`. |
| `TVX_AUTH` | Digest authentication for REGISTER (401) and INVITE (407). Needs `configuration/users.cfg` (copy `users.cfg.example`): `route[AUTH_PASSWORD]` maps the auth username to its password; the username must equal the device's SIP number. Off: the core is open — closed tests only. |
| `TVX_ANTIFLOOD` | pike request-rate guard: more than 32 requests / 2 s from one IP are dropped. |

`.env` holds `TVX_PUBLIC_IP` for docker compose, which passes it to rtpengine as
`RTPENGINE_PUBLIC_IP`. **Both copies of `TVX_PUBLIC_IP` must be the same IP** —
compose refuses to start when `.env` is missing. A `local.cfg` with
neither `TVX_SIP_DOMAIN` nor `TVX_PUBLIC_IP` fails the config check with the
token `NEITHER_TVX_SIP_DOMAIN_NOR_TVX_PUBLIC_IP_IS_DEFINED_IN_LOCAL_CFG`.

Non-secret tunables stay in `kamailio.cfg` itself: `TVX_RTP_FLAGS` (rtpengine
per-leg flags, plain RTP/AVP with ICE stripped), `TVX_RTPENGINE_SOCK` and the
tm timers (`fr_timer` 30 s, `fr_inv_timer` 120 s).

`local.cfg`, `users.cfg` and `.env` are gitignored — keep them that way.

---

## Run

```bash
cd deployment
# syntax/semantic check of the config before touching the running core
docker run --rm --entrypoint kamailio -v "$PWD/configuration:/etc/kamailio:ro" \
  ghcr.io/kamailio/kamailio:6.0.1-bookworm -c -f /etc/kamailio/kamailio.cfg
docker compose up -d
docker compose logs -f kamailio | grep --line-buffered TVX   # routing decisions
```

Every kamailio log line is prefixed with `{<1=request|2=reply> <CSeq> <Call-ID>}`,
so one call can be followed with a single `grep <Call-ID>`.

Live state via `kamcmd` (ctl socket inside the container):

```bash
docker exec thundervox-kamailio kamcmd -s unix:/tmp/kamailio_ctl ul.dump          # registrations
docker exec thundervox-kamailio kamcmd -s unix:/tmp/kamailio_ctl dlg.list         # live calls
docker exec thundervox-kamailio kamcmd -s unix:/tmp/kamailio_ctl dlg.stats_active # call counters
docker exec thundervox-kamailio kamcmd -s unix:/tmp/kamailio_ctl tm.stats         # transactions
docker exec thundervox-kamailio kamcmd -s unix:/tmp/kamailio_ctl rtpengine.show all
```

**Firewall — open to the internet:**

| Port | Proto | Purpose |
|---|---|---|
| 5060 | UDP + TCP | SIP signaling |
| 29000–30000 | UDP | RTP/RTCP media (rtpengine range; narrow test pool, widen for production) |

---

## Test with Zoiper (softphone stands in for the mobile app)

1. Register a Zoiper account against `TVX_PUBLIC_IP:5060` as user `1001`.
   Because it stays registered, it exercises the **online** path (no push).
2. Point an intercom/second softphone at the server and dial `sip:1001@TVX_PUBLIC_IP`.
3. Expect two-way audio (rtpengine relays it). Watch `[TVX]` logs for the routing
   decision (`callee ONLINE` vs `callee OFFLINE, parking + push`).

With push-wait off (default) a call to an unregistered number is answered with
`480` immediately — the caller's device must handle that cleanly.

To exercise the **push-wait** path, define `TVX_PUSH_WAIT` in `local.cfg`,
restart kamailio, let the callee go **unregistered**, place the call (caller
hears ringing, a push fires), then REGISTER the callee — the parked call connects.

---

## Known limitations / TODO

- **Synchronous push.** `route[PUSH]` calls the gateway synchronously and can block
  a SIP worker for up to `connection_timeout` (2s). Production: async push-gateway
  microservice, fire-and-forget.
- **Auth is a switch, off by default.** Without `TVX_AUTH` any host may register
  any number and originate calls — closed tests only. Credentials live in a
  config route (`users.cfg`), not a database; TLS and a real subscriber store
  are v1.
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

- **v0** — Docker Compose, single host *(current)*.
- **v1** — Kubernetes: stateless Kamailio edge (HA), rtpengine media pool behind
  `dispatcher`, Redis-backed presence, async push service, DB-backed location.
