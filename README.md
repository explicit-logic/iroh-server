# iroh-server

A macOS app that turns a personal Mac into an authenticated, peer-to-peer file
server — reachable from anywhere, with no port forwarding, no VPN, and no cloud
service holding the data. Close its window and it keeps running in the menu
bar; quit it and the daemon keeps serving.

Built on [iroh](https://github.com/n0-computer/iroh): peers are identified by
an ed25519 public key, connections are direct QUIC with relay fallback, and
everything is end-to-end encrypted by the transport.

> **Status:** design complete, implementation not started.
> See the [design spec](docs/superpowers/specs/2026-08-30-iroh-server-design.md).

## What it does

- **Share directories** with named devices, at `list` / `read` / `write`
  granularity per device, per share.
- **Invite a device from one screen** — a single permanent invite code you copy
  or scan. It is an iroh `EndpointTicket`: this Mac's endpoint ID and its relay,
  nothing else, so it connects on its own, and it never expires, so it can live
  in a signature or a printed card. It is an opaque blob, not something anyone
  reads out.
- **Pair by code or QR** — every unknown device lands in an Accept/Deny
  notification before it gets anything at all. Holding the code grants the right
  to ask, never access.
- **See every paired device** — icon by form factor, its name, which client app
  and version it runs, roughly where it is connecting from, and whether it is
  online or when it was last seen.
- **Keep serving with the UI closed.** A background agent owns the network and
  resumes at login.
- **Menu-bar presence** with a live connection count, Do Not Disturb, and a
  pause switch.

## Architecture

Two processes in one bundle. A SwiftUI app for the interface — a window plus a
menu-bar status item — and `irohd`, a Rust user LaunchAgent, for the network.

```
┌──── IrohServer.app (SwiftUI + AppKit) ─────┐
│  Devices · Resources · Settings            │
└──────────────────▲─────────────────────────┘
                   │ XPC
┌──────────────────▼─────────────────────────┐
│  irohd (Rust user LaunchAgent)             │
│  iroh Endpoint · authorization · redb      │
│    ├─ control ALPN  → share protocol       │
│    └─ iroh-blobs    → bulk file transfer   │
└────────────────────────────────────────────┘
```

The split exists so that sharing survives quitting the UI, so a Rust panic
cannot take down the interface, and so there is no FFI binding layer to
maintain. The daemon is a *user* agent rather than a system daemon because it
needs a login session for Keychain and TCC access — with the accepted trade-off
that sharing resumes at login, not at boot.

Bulk bytes move over `iroh-blobs`, which brings BLAKE3 verification, range
requests and resumption. Because blobs is pull-only, uploads run backwards: the
client announces a hash and the **server fetches it from the client**, verifies
it, and installs it atomically.

## Security model in one paragraph

iroh already provides encryption and cryptographic peer identity, so this
project adds the part iroh deliberately leaves open: **authorization**. There is
no password and no shared secret of any kind — no invite token, no PIN, no
pairing phrase. The invite code is an address, not a credential: what makes it
mean anything is that a 256-bit endpoint ID cannot be guessed, and what it buys
its holder is exactly one thing, the right to appear in an Accept/Deny prompt.
The credential is the `EndpointId` pinned at the moment a human accepts it, which
is why forgetting a device is immediate and complete, and why the code can safely
be permanent. The cost of that simplicity is written into the spec rather than
hidden: a code that gets out cannot be rotated, and the prompt shows nothing the
user can cryptographically verify.

The corollary is that everything a device *says* about itself — its name, icon,
app and version — is attacker-controlled and decorative. In the device list,
identity is the 6-character fingerprint shown beside it, never the name; at the
pairing prompt there is no verifiable field at all, which is a deliberate trade
the spec argues for explicitly. Location inverts the claim/observe direction: it
is observed from the connection rather than claimed, resolved locally against
a bundled database with no geo API ever called, kept only as a last-known value,
and never written to the audit log. Full threat model in
[§8 of the spec](docs/superpowers/specs/2026-08-30-iroh-server-design.md#8-threat-model-quotas-and-audit).

## Stack

| | |
|---|---|
| Interface | Swift · SwiftUI + AppKit · window + menu-bar status item |
| Core | Rust · [`iroh`](https://crates.io/crates/iroh) 1.1 · [`iroh-blobs`](https://crates.io/crates/iroh-blobs) 0.103 · redb |
| IPC | XPC, with peer code-signature validation |
| Platform | macOS 13+ (Apple Silicon and Intel) |
| Delivery | Notarized DMG, Developer ID · Sparkle 2 · `SMAppService` |

## Roadmap

| | | |
|---|---|---|
| M0 | Build gate | App + daemon, signed, XPC handshake — no UI |
| M1 | **Invite screen** | Permanent `EndpointTicket` and its QR, nothing else — the first screen shipped |
| M2 | Pairing | Accept/Deny, device list, presence, location |
| M3 | Read-only shares | `LIST`/`STAT`/`READ`, path confinement |
| M4 | Writes | Reverse-fetch upload, atomic install |
| M5 | Shell | Menu bar, Settings, DND, quotas, audit |
| M6 | Ship | Notarization, Sparkle, login agent |
| M7 | Client | Reference CLI → companion app |

M1 is a vertical slice, not a layer: the Invite screen cannot be drawn without
signed binaries, Keychain access, a bound endpoint and a working XPC contract
all working at once, so building it first turns this design's four riskiest
assumptions into observed facts behind a screen you can look at. Nothing about
file sharing is written until that holds.

## References

- [iroh](https://github.com/n0-computer/iroh) — p2p QUIC connections dialed by public key
- [iroh-blobs](https://github.com/n0-computer/iroh-blobs) — content-addressed blob transfer
- [iroh docs](https://docs.iroh.computer) — concepts, tickets, discovery
- [Sparkle](https://sparkle-project.org) — macOS app updates

Note for anyone reading older iroh material: `NodeId`, `NodeAddr` and
`NodeTicket` were renamed to `EndpointId`, `EndpointAddr` and `EndpointTicket`
in iroh 0.94. Tutorials predating that use the old names.
