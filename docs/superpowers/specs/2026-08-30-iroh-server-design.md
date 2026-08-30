# P2P macOS Resource Sharing Server — Design

**Status:** Draft · **Date:** 2026-08-30

A macOS application that turns a personal Mac into an authenticated,
peer-to-peer file server reachable from anywhere, without port forwarding, a
VPN, or a cloud intermediary holding the data. It presents as an ordinary
windowed app that keeps running in the menu bar once its window is closed.

---

## 1. Overview

### 1.1 Goals

- Expose selected directories on a Mac to a small, explicitly authorized set of
  peers over direct encrypted connections.
- Make the trust decision human-legible: a device list, an Accept/Deny prompt,
  per-device read/write grants.
- Keep serving while the UI is closed, and resume automatically after reboot.
- Ship as a normal Mac app: notarized, self-updating, no terminal required.

### 1.2 Non-goals

- **Not a general file-sync product.** No offline reconciliation, no conflict
  resolution, no "works on both machines simultaneously" semantics. This is a
  client browsing a server, live.
- **Not multi-user.** One macOS user account, one identity, one daemon.
- **Not a public file host.** Every connection is tied to a pinned peer
  identity. There is no anonymous or code-only access tier.
- **No Windows or Linux build** in this design. The core is portable Rust; the
  shell is not.

### 1.3 What iroh already provides (and what it does not)

This is worth stating explicitly, because it determines what actually needs
building.

iroh gives us, for free:

- **Transport encryption.** Every connection is QUIC/TLS, end-to-end encrypted.
- **Cryptographic peer identity.** Each endpoint holds an ed25519 `SecretKey`;
  its public key is the `EndpointId`, and it *is* the network address. You
  cannot talk to a peer without knowing its `EndpointId`, and you cannot
  impersonate one without its secret key.
- **NAT traversal.** Hole-punching with relay fallback, so a Mac behind a
  typical home router is reachable with no configuration.

iroh does **not** provide authorization. It will happily accept a connection
from any endpoint that knows our `EndpointId`. Everything in §4 exists to
answer the question iroh deliberately leaves open: *which* endpoints may
connect, and what may each of them do.

**Consequence for the original requirement "protect connection
(password/asymmetric encryption)":** the encryption half is already done and
needs no work. The other half needs no password either. There is no shared
secret anywhere in this design — no invite token, no PIN, no pairing phrase. The
only credential is the peer's own `EndpointId`, pinned at the moment a human
accepts it. See §4.3.

**Consequence for "share a stable connection link":** publishing an
`EndpointId` is harmless for confidentiality — a stranger holding it still has
no grant and can do nothing. It does, however, invite connection spam and
reveals that this endpoint exists. The invite code *is* that `EndpointId` plus
its relay (§4.3), so it is an address rather than a secret, and it is permanent
for the same reason the identity is. Its secrecy is not what protects you — the
Accept gate is. What circulating it costs is the ability to be left alone, so the
protections that carry weight are the Accept prompt and rate limiting (§8.3).

---

## 2. Architecture

Two processes, one bundle.

```
┌──────────────── IrohServer.app (UI) ─────────────────┐
│  SwiftUI + AppKit · Dock icon + menu-bar status item │
│  Devices · Resources · Settings · Accept/Deny UI     │
└───────────────────────────▲──────────────────────────┘
                            │  XPC (NSXPCConnection)
                            │  typed protocol, both directions
┌───────────────────────────▼──────────────────────────┐
│  irohd — Rust user LaunchAgent                       │
│  ┌────────────────────────────────────────────────┐  │
│  │ iroh::Endpoint  (ed25519 identity, QUIC)       │  │
│  │   ├─ Router ─┬─ control ALPN → share protocol  │  │
│  │   │          └─ iroh-blobs ALPN → BlobsProtocol│  │
│  │   ├─ authorization layer (devices + grants)    │  │
│  │   └─ store: redb (devices, grants, audit)      │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
             ▲                              ▲
      Keychain (identity)          shared directories (TCC)
```

### 2.1 Why a separate daemon

- **Serving outlives the UI.** The core requirement "auto-start after reboot"
  and the expectation that a paired device can fetch a file at 3am both mean
  the network stack cannot be owned by a window. Closing the window — or
  quitting the app outright — must not drop connections.
- **Crash isolation.** A panic in Rust — or in iroh-blobs, which is still
  pre-1.0 (§11) — takes down a restartable daemon, not the user's UI.
- **No FFI binding surface to maintain.** With an in-process staticlib we would
  own a UniFFI (or hand-written C-ABI) layer that has to be regenerated on
  every Rust signature change, and every async iroh API would need bridging
  into Swift concurrency. An XPC boundary is a message contract instead: it
  versions explicitly, it is inspectable, and the two sides can be developed
  and tested independently.

### 2.2 Why a *user* LaunchAgent, not a system LaunchDaemon

This is a load-bearing detail, not a preference.

- **Keychain.** The identity key lives in the login keychain, which is unlocked
  at login and belongs to the user's session. A system daemon running as root
  before login has no access to it.
- **TCC.** Reading `~/Documents`, `~/Desktop`, `~/Downloads` or any iCloud path
  requires TCC consent, which is per-user and granted through a GUI prompt.
  Only a process in the user's GUI session can trigger and hold that consent.
- **No admin prompt.** `SMAppService.agent(plistName:)` registers without an
  authorization dialog; `SMAppService.daemon` demands one at install time.

The cost is that the daemon starts at *login*, not at boot. A Mac that reboots
and sits at the login window is not serving. This is accepted and must be
stated in the UI — see §7.3 for the honest wording, and §11 for the
alternative if true at-boot availability is ever required.

### 2.3 The XPC contract

A single `NSXPCListener` in the daemon, Mach service name
`dev.irohserver.daemon`, declared in the agent plist.

Bidirectional: the app calls the daemon for commands; the daemon calls back
into the app for events via an exported interface on the same connection.

**App → daemon** (requests): `status()`, `identityInfo()`, `inviteCode()`,
`listDevices()`, `forgetDevice(id)`, `blockDevice(id)`,
`setDeviceMuted(id, bool)`, `renameDevice(id, label?)`, `listShares()`,
`addShare(bookmark, name)`, `removeShare(id)`,
`setGrant(deviceId, shareId, rights)`,
`resolvePendingConnection(id, decision)`, `setGlobalDND(bool)`,
`readAuditLog(range)`, `daemonVersion()`.

`inviteCode()` is a read, not a mint: the code is derived from the endpoint
identity and its relay (§4.3), so calling it twice returns the same value and no
call in this contract changes it.

**Daemon → app** (events): `connectionPending(PendingConnection)`,
`identityStateChanged(IdentityState)`,
`devicePresenceChanged(DeviceId, Presence)`,
`deviceDescriptorChanged(DeviceId, DeviceDescriptor)`,
`deviceLocationChanged(DeviceId, DeviceLocation?)`,
`activeConnectionCountChanged(Int)`, `transferProgress(TransferId, bytes, total)`,
`shareUnavailable(ShareId, reason)`.

`devicePresenceChanged` replaces a naive `connectionOpened`/`connectionClosed`
pair, because presence is a property of a device (§4.2) rather than of a
connection — a device may hold several at once, and the UI cares about the
aggregate.

**Hardening.** The listener validates every incoming connection with
`SecCodeCheckValidity` against a requirement pinning our Team ID and the app's
bundle identifier, so an arbitrary local process cannot drive the daemon.
Reject before servicing.

**Liveness.** The daemon holds no hard dependency on the app. If no app is
connected, events that require a human decision fall back to the policy in
§4.5 rather than blocking.

---

## 3. Identity and key storage

### 3.1 The endpoint key

A single ed25519 `SecretKey` generated on first launch. Its public half is the
`EndpointId` — the thing that goes in tickets and QR codes, and the thing
paired devices pin.

Stored in the login keychain as a `kSecClassGenericPassword` item:

| Attribute | Value |
|---|---|
| `kSecAttrService` | `dev.irohserver.identity` |
| `kSecAttrAccount` | `endpoint-secret-key` |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| `kSecAttrAccessGroup` | `<TeamID>.dev.irohserver` |
| `kSecAttrSynchronizable` | `false` — never leaves this Mac |

`ThisDeviceOnly` prevents the key entering an iCloud Keychain or a backup;
`AfterFirstUnlock` lets the daemon read it on a relaunch without a prompt.

**Access group.** The app and the daemon are signed with the same Team ID and
both declare the keychain access group entitlement, so the daemon can read the
key and the app can display the derived `EndpointId` without a second copy.
The secret itself is only ever *read* by the daemon; the app receives the
`EndpointId` over XPC and never touches the private half.

**Implementation note.** Keychain access is Security.framework, i.e. Swift or C.
The daemon is Rust, so it calls through a thin Objective-C/C shim compiled into
the daemon binary (or the `security-framework` crate, which wraps the same
APIs). Either way the daemon must be signed and entitled — an unsigned debug
build will fail to read the item, which is a predictable early-development
papercut worth knowing about in advance.

### 3.2 Rotation

Rotating the endpoint key changes the `EndpointId`, which invalidates every
ticket ever handed out and breaks every paired device's pin. It is therefore
**not** a routine operation and is not exposed in Settings. It exists only in
a "reset identity" flow that spells out the consequence and clears the device
list in the same transaction, so the state cannot end up half-migrated.

---

## 4. Pairing, devices, and grants

### 4.1 Data model

Persisted in a redb database at
`~/Library/Application Support/dev.irohserver/state.redb`,
owned exclusively by the daemon.

```
Device {
  id:            Uuid
  endpoint_id:   EndpointId       // the pin — immutable after creation
  fingerprint:   String           // 6-char rendering of endpoint_id, cached
  descriptor:    DeviceDescriptor // last self-reported — untrusted, see §4.2
  user_label:    Option<String>   // user override; wins over descriptor.name
  location:      Option<DeviceLocation> // observed, never claimed — §4.2
  paired_at:     OffsetDateTime
  last_seen_at:  Option<OffsetDateTime>  // server clock, never client-claimed
  muted:         bool             // suppress notifications from this device
}

Share {
  id:            Uuid
  bookmark:      Vec<u8>         // security-scoped bookmark, not a path
  display_name:  String
  default_rights: Rights         // applied to devices with no explicit grant
  added_at:      OffsetDateTime
}

Grant {
  device_id:     Uuid
  share_id:      Uuid
  rights:        Rights
}

bitflags Rights {
  LIST  = 0b001   // see that a path exists, its name, size, mtime
  READ  = 0b010   // fetch contents
  WRITE = 0b100   // create, modify, rename, delete
}
```

`Rights` is a bitflag set, not an enum ladder: **all eight combinations are
representable and none is normalised away.** No implication is applied in
either direction — `WRITE` does not confer `READ`, and `READ` does not confer
`LIST`. Two combinations that look odd are in fact the interesting ones:

- `LIST` alone — a device sees that `Invoices/` exists and how big it is, but
  cannot open anything in it.
- `WRITE` alone — a drop box. A device can deposit files and cannot read back
  what is there, including its own uploads.

Combinations that grant an operation without the traversal needed to reach it
(`READ` without `LIST`, say) are legal and simply behave as written: the
device must already know the exact path, because `LIST` will not reveal it.
The UI presents the three common presets — *List only*, *Read*, *Read &
write* — with the full matrix behind an "Advanced" disclosure, so the model
stays expressive without making the common case fiddly.

**Why bookmarks instead of paths.** A security-scoped bookmark survives the
directory being renamed or moved, survives reboot, and is the only form that
will still work if this app is ever sandboxed for the App Store. Resolving one
that has gone stale produces a clear "share unavailable" state in the UI rather
than a silently empty directory.

### 4.2 The device item

A paired peer is a **device**, not a person. This is the honest granularity: an
iroh `EndpointId` belongs to one endpoint — one app install on one piece of
hardware — so it was never able to represent a human who owns both a phone and
a laptop. Modelling devices directly makes "forget the stolen phone, keep the
laptop" expressible, which it would not be if both hid behind a single entry.

The cost is that a person with three devices pairs three times and occupies
three rows. Accepted: pairing is a ten-second QR scan, and a grouping layer
above devices would buy tidiness at the price of the property above. See §11
for when that trade might be worth revisiting.

**Descriptor** — what a device reports about itself:

```
DeviceDescriptor {
  form_factor: FormFactor,   // drives the icon
  name:        String,       // "iPhone 17", "MacBook Pro M5"
  app_name:    String,       // "Iroh Share for iOS"
  app_version: String,       // semver — "1.4.2"
}

enum FormFactor { Phone, Tablet, Laptop, Desktop, Unknown }
```

**Presence** — what the daemon observes, not what the device claims:

```
enum Presence {
  Online  { since: OffsetDateTime, connections: u8 },
  Offline { last_seen_at: Option<OffsetDateTime> },
}
```

`Online` means at least one open control-ALPN connection. QUIC keepalive (30s)
holds an idle connection open, so a device that is connected but transferring
nothing still reads as online; a missed keepalive closes the connection and
stamps `last_seen_at`. Both `since` and `last_seen_at` are taken from the
**server's** clock at connect and disconnect. A client-supplied timestamp is
never stored — otherwise a device could report itself as last seen in the
future, or never.

Presence changes are coalesced over 2s before reaching the UI, so a connection
flapping on a train does not strobe the device list.

Note what the star topology gives away for free: devices connect to this Mac
and never to one another, so **no device learns any other device's presence,
name, or existence.** Presence is local knowledge only.

**Location** — observed, not reported. Note that it is deliberately *not* a
field of `DeviceDescriptor`: the device never tells us where it is, we infer it
from the address it connects from.

```
DeviceLocation {
  label:       String            // "Paris, France"
  country:     Option<String>    // ISO 3166-1 alpha-2, for flag and sorting
  precision:   Precision
  resolved_at: OffsetDateTime    // server clock
}

enum Precision { City, Country, LocalNetwork, Unavailable }
```

Resolution runs on every connect, in this order:

1. **Find a direct path.** `Connection::paths()` returns the connection's open
   paths. A connection typically opens a relay path first and gains a direct
   one once holepunching succeeds; we want the remote transport address of the
   direct path.
2. **No direct path → `Unavailable`.** Do *not* geolocate the relay. Doing so
   would label every relayed device with the relay's own city — a confident
   wrong answer, which is worse than no answer. This is not an edge case:
   relaying is iroh's normal fallback whenever holepunching fails, so a real
   share of connections land here.
3. **Private address → `LocalNetwork`**, displayed "Local network". Covers
   RFC1918, CGNAT `100.64/10`, link-local, loopback, and IPv6 `fc00::/7` and
   `fe80::/10`. A city guess is meaningless for a LAN peer, and "this device is
   on your network" is the more useful fact anyway.
4. **Otherwise look the address up** in the bundled database: city hit →
   `City`, country-only hit → `Country`, miss → `Unavailable`.
5. **Re-resolve on upgrade.** `paths_stream()` yields a fresh snapshot when a
   relay-only connection gains a direct path, so a device that first appears as
   `Unavailable` fills in its location moments later without reconnecting.

Pin the exact path accessors against the iroh version at implementation time.
Older iroh material reaches for a `ConnectionType` enum for this; it does not
exist in 1.x, where the per-path API replaced it.

**Resolution never touches the network.** No third-party geolocation API, ever.
Calling one would hand the IP address of every device that connects to you to a
stranger, on every connection — leaking your paired devices' addresses and
building someone else's dataset out of your users' movements. The database is
bundled in `Contents/Resources/` and refreshed by ordinary app updates through
Sparkle, so there is no second update channel and no runtime dependency.

**Choosing the database is a licensing decision as much as a technical one.**
MaxMind's GeoLite2 requires an account and its licence constrains
redistribution, which is awkward for something bundled inside an app; DB-IP
City Lite and IP2Location LITE are the usual bundleable alternatives and oblige
us to carry attribution in the acknowledgements. Expect tens of megabytes for
city-level data against single-digit megabytes for country-only — a real
bundle-size trade if city precision turns out not to matter. Decide at
implementation and record the attribution obligation then (§11).

**Trust posture — and note this inverts everything else in §4.2.** Every other
field here is attacker-*controlled*: the peer states a name and we cannot check
it. Location is the reverse — we observe it, the peer never states it, so a
peer cannot set it directly. What a peer *can* do is mislead it: a VPN, Tor, or
a corporate egress puts a device wherever that exit sits. And it can simply be
wrong, from a stale database or carrier-grade NAT. So location is untrusted in
a different way from a name: not forged text, but an inference that is
sometimes confidently incorrect.

The consequence matches `app_version` below: **location must never gate
authorization.** "Only allow writes from France" is not a security control — a
VPN defeats it in a click, and it locks the user out the moment they travel. It
is information for a human who notices something odd, and nothing more.

**Retention: last known only.** `Device.location` is one nullable field,
overwritten on each connect. **Location is never written to the audit log**
(§8.4), and no history is kept anywhere in the system. So the device list can
answer "where is my phone right now" while nothing can reconstruct where it has
been. That limit is deliberate: a location column times an append-only log
would quietly turn this app into a movement tracker for everyone the user has
paired with, which is not a thing to build by accident. Resolution can also be
switched off entirely (§6.5), leaving the field empty.

**The list row.** Name and fingerprint with presence on the first line; client
app and version with location on the second:

```
┌────────────────────────────────────────────────────────────┐
│ [iphone]  iPhone 17 · 7f3a·b901                     Online │
│           Iroh Share for iOS 1.4.2           Paris, France │
├────────────────────────────────────────────────────────────┤
│ [laptop]  MacBook Pro M5 · 2c8e·d417       Last seen 14:32 │
│           Iroh Share for macOS 1.4.0         Local network │
├────────────────────────────────────────────────────────────┤
│ [?]       Android tablet · 4a17·ee02       Last seen 3 Mar │
│           Iroh Share for Android 0.9.1                   — │
└────────────────────────────────────────────────────────────┘
```

Icons are SF Symbols selected by `form_factor` — `iphone`, `ipad`,
`laptopcomputer`, `desktopcomputer`, and `questionmark.circle` for `Unknown`.

Status renders as **Online** preceded by a green dot when online, otherwise as
a relative time: "Last seen 2 minutes ago" under an hour, a clock time under a
day, a weekday under a week, a date beyond that. A device that has never
connected since pairing reads "Never connected", not an empty cell. The dot
carries no information the text does not, so colour is never the only channel.

Location renders by `precision`: `City` as "Paris, France", `Country` as
"France" alone, `LocalNetwork` as "Local network", and `Unavailable` as an em
dash — as in the third row above, which is connected over a relay. The dash is
not an error state and should not be styled as one; the detail view explains
which case applied, so "relayed, so we cannot tell" is distinguishable from
"not in the database".

A stale location is worse than none, so a location older than its device's
`last_seen_at` is never shown against a currently-online device: if a
reconnect has not yet resolved, the field is blank rather than showing where
that device used to be.

Selecting a row opens the detail view: full `EndpointId`, the per-share grant
matrix (§4.1), mute toggle, transfer history, and Forget.

**Every descriptor field is attacker-controlled.** The peer states its own
name, form factor, app and version, and nothing verifies any of it. The rules
that follow are not optional:

1. **`form_factor` is a closed enum — never a client-supplied string or
   image.** A peer chooses among five variants and so cannot render arbitrary
   art in your UI. Unrecognised values decode to `Unknown`, which is also what
   makes the enum forward-compatible when a client ships a form factor this
   build predates.
2. **Text fields are capped and sanitised before storage.** `name` 64 chars,
   `app_name` 64, `app_version` 32; strip C0/C1 control characters; strip bidi
   overrides (U+202A–U+202E, U+2066–U+2069) — without that, a device named
   `holiday\u202Egnp.exe` renders in the list as `holidayexe.png`;
   NFC-normalise; render as plain text with no markup interpretation.
3. **The name is never identity.** The 6-character fingerprint of the
   `EndpointId` sits beside the name in the device row and in every audit entry.
   Two devices may claim the same name; they cannot share a fingerprint. Note
   the one place it does *not* appear: the pairing prompt, which by the decision
   in §4.4 shows nothing verifiable at all, because at that moment the device is
   not yet one the user has any reason to recognise.
4. **`app_version` must not gate authorization.** It is display and support
   information. A peer can claim any version, so a rule of the form "allow
   writes only from ≥1.4" is theatre.
5. **A user-set `user_label` always wins.** Once the user names a row, the
   self-reported name moves to the detail view. This is the defence against a
   device renaming itself to impersonate one the user already trusts.

**Updates.** The descriptor arrives in `HELLO`, and only there — an app update
or a rename takes effect on the next reconnect, which an app update entails
anyway. One arrival point means one place to validate. A descriptor differing
from the stored one is accepted, emitted as `deviceDescriptorChanged`, and
recorded in the audit log as a rename, because a device quietly becoming a
different device is precisely what a user needs to be able to notice after the
fact.

### 4.3 The invite code

One artifact, and it is an iroh `EndpointTicket` — nothing of our own layered on
top of it. The ticket carries the endpoint identity and the relay to reach it,
which is exactly what a client needs in order to dial, and no more:

```
EndpointTicket → EndpointAddr {
  endpoint_id:   EndpointId,   // 32 bytes — the whole public key, irreducibly
  relay_url:     RelayUrl,     // where to reach this endpoint first
  direct_addrs:  {},           // deliberately empty — see below
}
```

Serialised by iroh's own ticket encoding — the string `inviteCode()` returns and
the QR carries:

```
# illustrative shape, not a real ticket; the prefix comes from iroh's Ticket::KIND
endpointaeaqjs4bkvpfhkzhqzqxfz4h7d7iu5qkzqm5fp3lspxgnbxjcaacaidaadaaaaaaqbjdbmiaqdaidaqcaaaaaa
```

It is an opaque blob and it is meant to stay opaque. No groups, no hyphens, no
check symbol, no alphabet chosen for legibility, and no accommodation for
transcription. This value is copied, pasted, or scanned; the design does not
pretend a human will carry it by hand, and it offers nothing that would suggest
otherwise. Anything that parses is dialled, anything that does not is refused
locally as malformed before the network is touched.

**Why iroh's ticket and not an encoding of our own.** Because the payload is
precisely what iroh already defines a ticket to be, and a wrapper would buy
nothing. Using the native type deletes a set of decisions this design previously
had to make and get right: a relay lookup table shipped with the app, its refresh
through app updates, and the fallback path for a client whose table predates a
newly-added relay. The relay URL travels in full instead. It costs some forty
characters in a value nobody reads, which is the correct trade once the value is
not read.

**No invite token.** An earlier draft carried a rotatable 32-bit token to
separate "someone I invited is knocking" from "a stranger who obtained my
endpoint ID is knocking". It is gone, and with it rotation and every handshake
branch that depended on it (§4.4). The reasoning: to dial at all, a caller must
already hold the 256-bit `EndpointId`, which is uniformly random and cannot be
enumerated or guessed. Possession of the ticket therefore *is* the right to ask,
with no second secret layered over the first, and the token was never the thing
keeping strangers out — the Accept gate was.

What that costs is worth stating plainly, because it is a real loss. A token
could be rotated: every old copy died, every paired device carried on
untouched. There is now no way to retire a ticket that has got out. The remedies
are narrower — **Deny and block** the specific endpoint that will not stop
knocking (§4.4, §4.7), the pairing-window restriction that refuses new pairing
wholesale (§4.4), or resetting the endpoint identity, which per §3.2 breaks the
pin of every device ever paired. For a value that is an address rather than a
credential this is a defensible position, but it means a widely-circulated ticket
is a standing invitation to be knocked on, and the rate limits of §8.3 are what
absorb it.

**It is stable and it never expires.** No nonce to burn, no TTL to run out, and
now nothing to rotate: the ticket is a function of the identity and its relay, so
the same value works in a year. It can live in a password manager, an email
signature, or a printed card, and re-sending it to someone who mislaid it costs
nothing.

One honest qualifier: the ticket is stable as long as its *relay* is. If the user
moves to a self-hosted relay, or n0 retires the one named inside it, existing
copies point somewhere no longer useful. Discovery covers that case (below) and
is now the only thing that does, which raises what publishing to discovery is
worth — §11 revisits it.

**What the ticket does and does not confer.** Possession grants the right to
*ask*. It carries no grant, no rights, and no access: an unknown device holding a
valid ticket still lands in the Accept/Deny prompt of §4.4, and a Deny leaves it
with nothing. This is the entire security argument for a permanent, unrevocable
ticket, and it is why the rate limits in §8.3 stop being defence-in-depth and
become load-bearing.

**Why `direct_addrs` is left empty.** iroh's `EndpointAddr` can carry direct
socket addresses and its ticket will happily serialise them. We omit them
deliberately. They change every time the Mac joins a different network and there
are usually several, so embedding them would both inflate the ticket and stale it
immediately — they are the one part of this value capable of going out of date on
its own. A ticket therefore always makes first contact **through the relay**, and
the connection upgrades to a direct path once holepunching succeeds, which is
iroh's normal behaviour rather than a compromise. Minting has to pin this
explicitly: build the `EndpointAddr` from the endpoint ID and relay alone, never
from the endpoint's current address set, or the property is lost silently the
first time a ticket is minted on a laptop with four interfaces up.

Two things follow. First, discovery (`address_lookup::DnsAddressLookup`) is not
required for a ticket to work: the relay inside it is enough to connect. It stays
valuable as the recovery path for a relay that has moved, so it is worth
publishing — but a failure to publish degrades robustness rather than breaking
pairing outright. §11 records what publishing discloses.

Second, the location logic in §4.2 lines up with this by construction: a device
pairing from a ticket is relayed at the moment it first appears, so its location
reads `Unavailable` and fills in seconds later when the direct path arrives. That
is the expected sequence, not a bug to chase.

**Transport.** The ticket is plain text. The QR on the Invite screen (§6.1)
encodes those same characters, so scanning and pasting produce identical results
and there is exactly one value to reason about. The app registers no URL scheme
for invitations: there is no link to tap, which costs the recipient a paste where
a URL would have cost them nothing. A deliberate trade, and reversible later as a
pure convenience wrapper around the same ticket without touching the model.

### 4.4 The pairing handshake

1. Client dials the control ALPN and sends
   `HELLO { protocol_version, descriptor }`, where `descriptor` is the
   `DeviceDescriptor` of §4.2 — validated and sanitised on arrival, before it
   reaches storage or the UI. There is no token field: holding the ticket is
   what got the caller this far, and nothing else is presented.
2. Daemon classifies the caller by `EndpointId`. Three cases, and the collapse
   from six is the whole structural benefit of dropping the token:
   - **Blocklisted `EndpointId`** → close immediately, checked before anything
     else. Because the ticket is permanent and cannot be revoked, a denied
     device keeps a working copy of it, so the blocklist is the only thing that
     stops it knocking again (§4.7).
   - **Known device** → straight to serving (§5), no prompt. The descriptor is
     compared against the stored one and any change is logged as a rename.
   - **Unknown** → pending approval (step 3), subject to the rate limits and the
     pending cap of §8.3. Reaching this point proves the caller holds the
     ticket, and nothing beyond that distinguishes a device the user invited
     from one that was forwarded the ticket by somebody else.

   If the pairing-window restriction is enabled (below), an unknown caller
   arriving outside an open window is closed immediately instead: no error
   detail, no share metadata, nothing that confirms what this endpoint is.
3. Daemon parks the connection as a `PendingConnection` and emits
   `connectionPending` over XPC.
4. App raises a `UNNotificationRequest` with **Accept** and **Deny** actions,
   showing the device's icon, self-reported name, and app name and version — all
   rendered as untrusted text per §4.2.

   **Every field on this prompt is attacker-controlled, and nothing on it is
   verifiable.** An earlier draft also showed the caller's 6-character
   fingerprint so two humans could confirm out of band that the device knocking
   was the device expected. That is gone, and nothing replaces it. The
   consequences, to be accepted knowingly: two devices knocking in the same
   minute are distinguishable only by the names they claim, a device can name
   itself after one the user already trusts, and an attacker who obtained the
   ticket presents exactly what an invited device presents. This prompt is a
   consent gate on *when* pairing may happen, not a check on *who* is asking.
   §8.2 records it as undefended rather than dressing it up as a mitigation.

   The fingerprint remains the identity of an *already paired* device and stays
   in the device list and Settings (§4.2, §6.5). Giving a device the user has
   already accepted a stable handle is a different job from authenticating a
   stranger, and only the second one is being abandoned here.
5. On Accept: create the `Device`, apply the default grants for existing shares,
   resume the connection. On Deny: close and record the refusal so a repeat
   dialler is rate-limited (§8.3). Deny offers a second form, **Deny and
   block**, which adds the `EndpointId` to the blocklist checked in step 2 — the
   only way to stop a device that holds the ticket and keeps trying.

**Pairing window — a restriction now, not the gate.** By default an unknown
dialler prompts whenever it arrives, so sending someone the ticket is sufficient
and they connect on their own; that is the promise the invite code makes and it
should not require a second action from the user. A Settings toggle, **Only
accept new devices during a pairing window** (default off), inverts that: with it
on, unknown diallers are refused unless the user has opened a window from
Settings or the menu bar — "Accept new connections for the next 10 minutes."

The clamp carries more weight than it did, because a circulated ticket can no
longer be rotated away, so this is the one control that stops knocking without
blocking endpoints one at a time. It is distinct from Global DND (§4.6), which
auto-denies new requests indefinitely rather than for a window, and from Pause
sharing, which refuses paired devices too.

### 4.5 When the UI is not running

The daemon outlives the app, so approval prompts can arrive with nobody to
answer them. Policy, in order:

1. If the app is connected over XPC → prompt normally.
2. If not, and Settings has **Launch UI to ask** enabled (default) → daemon
   launches the app via `SMAppService`/`NSWorkspace`, waits up to 20s for it to
   connect, then prompts.
3. Otherwise, or on timeout → **auto-deny** after 60s, and queue a
   `MissedRequest` shown the next time the UI opens.

Fail closed, always. A pending connection consumes a slot, so pending requests
are capped (default 3) and further unknown diallers are dropped without parking.

### 4.6 Do Not Disturb — two distinct things

The original requirement lists "dnd" in the device list, which conflates two
behaviours that need separating:

- **Per-device mute** (`Device.muted`) — cosmetic. Existing grants keep
  working, transfers proceed, but no notifications are raised for this device.
  For the noisy device you deliberately gave access to.
- **Global DND** — behavioural. Auto-denies *new* pairing requests and
  suppresses all notifications. Already-paired devices keep their access; this
  is not a kill switch.

Both are distinct from a third thing the UI should also offer: **Pause
sharing**, which refuses all connections including paired devices, without
deleting anything. That is the kill switch.

Mute is per-device and not per-person, which is the granularity you actually
want: a phone that syncs constantly can be silenced while its owner's laptop
still raises notifications.

### 4.7 Forgetting a device

**Forget** removes the device's grants, closes any live connection, and burns
the pin. Because the device's `EndpointId` was the credential and there is no
bearer token to leak, revocation is immediate and complete — a forgotten
device holding an old ticket is exactly as powerless as a stranger.

The row is not deleted silently: the device list keeps a "Forgotten" section
for 30 days recording name, fingerprint and when it was forgotten, so a
mistaken Forget can be recognised and the device re-paired deliberately rather
than by guesswork. Re-pairing mints a new `Device` with a new `id`; nothing is
resurrected.

Note the limit of Forget under a permanent ticket: it removes *access*
completely, but the device still holds a working ticket and can ask again. That
is usually what you want — a family member's reinstalled phone should be able to
re-pair — but when it is not, **Forget and block** is offered alongside it, and
the blocklist is the first check in §4.4. It is also nearly the only instrument
available: with no token to rotate (§4.3), a ticket that has got out cannot be
retired, so blocking endpoints one at a time and the pairing-window restriction
are what remain.

---

## 5. The share protocol

### 5.1 Two ALPNs, one connection

| ALPN | Handler | Carries |
|---|---|---|
| `irohserver/ctrl/1` | our `ShareProtocol` | metadata, directory ops, control |
| iroh-blobs' `ALPN` | `BlobsProtocol` | bulk file bytes |

Both are registered on one `iroh::Router`. Control messages are small and
request/response; bytes move on the blobs protocol, which brings BLAKE3
verified streaming, range requests, resumption, and cross-device dedup that
we would otherwise have to write ourselves.

Versioning lives in the ALPN string. A `ctrl/2` would be registered alongside
`ctrl/1` during any transition, so an older companion app keeps working.

### 5.2 Control messages

Postcard-encoded, length-delimited, one request/response pair per QUIC
bidirectional stream — so requests are naturally concurrent and a slow
directory listing cannot head-of-line block a small `STAT`.

| Message | Rights | Response |
|---|---|---|
| `HELLO` | — | `ServerInfo { protocol_version, display_name, shares[] }` |
| `LIST { share, path, cursor? }` | `LIST` | `Entries { entries[], next_cursor? }` — paginated, 500/page |
| `STAT { share, path }` | `LIST` | `Meta { size, mtime, kind, hash? }` |
| `READ { share, path }` | `READ` | `Blob { hash, size }` — then fetch over blobs ALPN |
| `WRITE { share, path, hash, size }` | `WRITE` | `Ack` — see §5.3 |
| `MKDIR { share, path }` | `WRITE` | `Ack` |
| `DELETE { share, path, recursive }` | `WRITE` | `Ack` |
| `RENAME { share, from, to }` | `WRITE` | `Ack` |
| `WATCH { share, path }` | `LIST` | stream of `FsEvent` until cancelled |

`READ` returns a hash rather than bytes. The client then fetches that hash over
the blobs ALPN, which is what makes a 40 GB video resumable across a dropped
connection at zero protocol cost. The daemon imports the file into its blob
store on demand and tags it; the store is a filesystem store (`store::fs`,
redb-backed) under Application Support, size-capped and LRU-evicted, since it
is a cache of content that already exists on disk.

### 5.3 Writes, and why they run backwards

**iroh-blobs is pull-only.** There is no push: a provider serves, a requester
fetches. A naive design would have the client push its bytes to the server,
and there is no API for that.

So `WRITE` inverts. The client adds the file to its *own* blob store, sends
`WRITE { path, hash, size }`, and the **server then fetches that hash from the
client** over the blobs ALPN — the connection is already bidirectional, and
either side can act as provider. On completion the server verifies the BLAKE3
hash matches what was declared, then atomically installs the file
(write to a temp file in the destination directory, `fsync`, `rename`).

This falls out well: uploads get the same verification and resumption as
downloads, and a partial upload leaves no partial file at the destination.

It does require the companion client to run a blob store and accept inbound
connections on the blobs ALPN — a real obligation on the client, and the main
argument against approach A that we accepted with our eyes open.

### 5.4 Path confinement

Every path in every request is untrusted input. The rules, applied in the
daemon before any filesystem call:

1. Reject absolute paths, and any component equal to `..` or empty.
2. Reject anything that is not valid UTF-8, and normalise Unicode to NFC
   (macOS filesystems are NFD-leaning; without this, `café` from a client will
   not match `café` on disk).
3. Join to the share root, then `realpath` the result and verify the resolved
   path is still **inside** the resolved share root. This is the check that
   catches symlinks pointing out of the share, and it must happen on the
   resolved path, not the joined one.
4. Refuse to follow symlinks that escape the root; surface them as a distinct
   `SymlinkEscaped` entry kind in `LIST` so the client can show them greyed out
   rather than silently omitting them.
5. Re-check on every operation. Do not cache the resolution — a directory can
   be replaced with a symlink between two requests (TOCTOU).

Additionally: never serve `.DS_Store`, never serve anything inside a `.git`
directory unless the share root *is* the repository, and honour macOS hidden
flags.

### 5.5 Errors

A closed enum, never free-form strings: `NotFound`, `PermissionDenied`,
`ShareUnavailable`, `Conflict`, `QuotaExceeded`, `InvalidPath`, `TooLarge`,
`Internal`. `PermissionDenied` and `NotFound` are deliberately
indistinguishable for paths the caller lacks `LIST` on, so the error channel
cannot be used to probe for the existence of files outside a grant.

---

## 6. Screens and macOS integration

### 6.1 Invite screen

**This screen is built first** — see §10. One honest caveat on that ordering:
the screen renders the endpoint identity, so it cannot precede identity
existing. What it can do, and the reason to put it first, is *drive* identity
into existence as the first vertical slice. Delivering it forces a working path
through every layer at once — Keychain → endpoint bind → XPC → SwiftUI — which
is exactly the shape of risk worth retiring before anything else. M0 beneath it
has no UI at all, so nothing competes for "first screen".

```
┌──────────────────────────────────────────────┐
│  Invite a device                             │
│                                              │
│         ┌────────────────────┐               │
│         │     [ QR code ]    │               │
│         └────────────────────┘               │
│                                              │
│  Invite code — never expires                 │
│  ┌─────────────────────────────────────┐     │
│  │ endpointaeaqjs4bkvpfhkzhqzqxfz4h7d │     │
│  │ 7iu5qkzqm5fp3lspxgnbxjcaacaidaadaa │     │
│  │ aaaaqbjdbmiaqdaidaqcaaaaaa          │     │
│  └─────────────────────────────────────┘     │
│                                              │
│         [ Copy invite code ]                 │
└──────────────────────────────────────────────┘
```

**One value, two renderings.** That is the whole screen:

1. **The invite code** (§4.3): the `EndpointTicket` as one unbroken monospace
   run, soft-wrapped to the width of the field. No hyphens, no groups, no
   chunking of any kind — the value is not read by a human, and visual
   scaffolding for reading it would only imply that it is. It never expires, so
   the code on screen today is the code on screen next year — safe to
   screenshot, print, or leave in a wiki.
2. **The QR code**, encoding those same characters as plain text — not a URL.
   Scanning and pasting therefore produce identical results.

The endpoint ID and the fingerprint are deliberately absent, and so is any
out-of-band verifier. The code *is* the endpoint ID plus its relay, so a
separate ID field would show the user a substring of what is already on screen
and invite the question of which one to send. One value on the screen, one Copy
button, nothing to choose between.

**There is no code-verification step, by decision.** An earlier draft had the two
humans compare part of the value out of band — Alice reading a group aloud, Bob
checking his copy — to defeat an attacker who substituted their own code in a
channel they control. That is gone along with everything else in this design
meant to be spoken, and the Accept prompt's fingerprint went with it (§4.4).
Nothing replaces either. A ticket substituted in transit pairs the attacker's
device if the user accepts, and §8.2 lists that as undefended. What remains is
procedural rather than technical: send the code over a channel you trust, and be
able to account for *why* a device is knocking before accepting it.

**Rendering the QR.** Generated locally with Core Image's `CIQRCodeGenerator`:
no dependency to add, and no third-party QR service — which would mean
uploading an invitation secret to a stranger. The details that decide whether
scanning actually works:

- Error-correction level **M**, with the module count allowed to grow with the
  payload. A ticket carrying a full relay URL runs to a hundred-odd characters
  once base32-encoded, so the code will not be small; size the view from the
  generated module count rather than assuming a fixed version. Omitting direct
  addresses (§4.3) stops it growing further, but that is not licence to hardcode
  a version — a self-hosted relay URL can be long.
- Draw it **dark-on-light always, including in dark mode**, on an explicit white
  plate. An inverted QR defeats a good number of scanners, and it is the single
  most common way a dark-mode QR screen ships broken.
- Keep the 4-module quiet zone.
- Render vector rather than a bitmap, so it stays sharp as the window resizes.

**Permanence is stated, not assumed.** "Invite code — never expires" labels the
code, because a user who cannot tell will re-open this screen before every
invitation to check for a fresh one. There is no countdown, no regenerate
button, and no expired state to design around.

**There is nothing to rotate.** No regenerate button here, and none in Settings
either: the code is a function of the endpoint identity and its relay (§4.3), so
the only way to change it is to reset the identity, which per §3.2 breaks the pin
of every device ever paired. That lives under Settings → Identity with its own
warning (§6.5), and it is not really a remedy for a leaked code — it is an
admission that the identity itself is being abandoned. A user who asks how to
invalidate a code they sent by mistake should be told the truth: they cannot, but
they can decline the device when it knocks, block it, or close pairing entirely
(§4.4).

**Pasting it in is the other half of this feature.** The companion app's entry
field takes the value as-is: trim surrounding whitespace and newlines, hand the
string to iroh's ticket parser, and report a parse failure as "that isn't a valid
invite code" before the user reaches for Connect. No case folding, no character
substitutions, no partial-input repair. The value arrives by clipboard or camera
or not at all, and a field that tried to fix a mistyped ticket would be
advertising a way of moving it that this design deliberately dropped. Validate
locally before touching the network, always.

**States.** Three, all shipping in M1 — a permanent code removes the fourth:

| State | Cause | What the user sees |
|---|---|---|
| Generating | first launch, key being created | progress, no code |
| Ready | identity bound | the code and its QR |
| Unavailable | daemon not running, or XPC down | explanation and Retry — never a blank QR frame |

Unavailable matters more than it looks. This is the first screen a new user
sees, so "the agent failed to register" has to read as a diagnosable problem
rather than an empty window.

**The code is not a secret, and the UI should not pretend otherwise.** It is
meant to be sent, screenshotted, and pasted; it grants only the right to ask
(§4.3). So it gets no concealed-clipboard treatment, no blurring, and no
screenshot warnings — theatre around a value the user is about to paste into a
group chat teaches them to distrust the warnings that matter. What it does get is
an honest one-liner under the Copy button: anyone with this code can *ask* to
connect, you decide each time, and it cannot be taken back once sent.

**Accessibility.** The code is selectable text, never an image, so the keyboard
can reach it and it survives being copied anywhere. It is not text in order to be
spoken: VoiceOver should announce the field as a copyable invite code and offer
the Copy action rather than reciting a hundred characters of base32 that nobody
can act on by ear. Copy is therefore the accessible path to this value, which
makes keyboard reachability and a spoken completion announcement requirements
rather than polish — not merely an animated checkmark. The QR carries a label
saying it encodes the same code shown above it.

### 6.2 Window and menu bar

**A regular app, not an agent.** `LSUIElement` is unset: the app runs at
`.regular` activation policy, so it has a Dock icon, its own menu bar, a place
in ⌘-Tab, and a main window that opens at launch. An earlier draft made this an
`LSUIElement` agent with no window at all; that hid the app from every habit a
user has for finding an app, and made a background service that holds their
files harder to inspect than it should be. Visibility is the right default for
something serving a home directory to the network.

**Closing the window does not quit.** `applicationShouldTerminate`
`AfterLastWindowClosed` returns `false`. Closing the last window leaves the app
running with its Dock icon and status item in place; clicking the Dock icon
(`applicationShouldHandleReopen`) or choosing Open from the status menu brings
the window back. The Dock icon deliberately *stays* after the window closes
rather than the app dropping to `.accessory` — an app that vanishes from the
Dock while still running reads as a crash, and the Dock is the most obvious way
back to a window the user just closed.

This split is the whole point of the two-process design (§2.1) rendered in the
UI. Three separate things can stop, and the interface has to keep them
distinct:

| Action | Window | UI process | Daemon / serving |
|---|---|---|---|
| Close window (⌘W, red button) | closed | running | serving |
| Quit (⌘Q, or status menu) | closed | exits | **still serving** |
| Stop sharing and quit | closed | exits | stopped |

**Status item.** An `NSStatusItem` whose icon carries a badge with the active
connection count, per the original requirement. Zero connections shows the bare
icon, not a "0". It is present whether or not a window is open, which is what
makes closing the window safe: there is always a visible affordance proving the
app is still there.

Status menu: connection count and who is connected · Open IrohServer (reopens
the window) · Pause sharing · Accept new connections for 10 min · Invite a
device · Open Devices / Resources / Settings · Quit.

"Invite a device" opens §6.1. The separate "Copy my code" and "Show QR" items
an earlier draft had here are deliberately collapsed into it, so there is
exactly one place in the app where an invitation is minted and exactly one
place to look for it.

**Quit quits the *UI only*, and says so**, because the daemon keeps serving.
This now also covers ⌘Q from the app menu, which a windowed app gets for free
and which users reach for without reading anything — so the app menu item is
titled "Quit IrohServer (keep sharing)" rather than plain "Quit", and a
separate "Stop sharing and quit" fully stops the agent. Conflating these would
be the single most confusing thing this app could do.

### 6.3 Notifications

`UNUserNotificationCenter` with a category carrying **Accept** and **Deny**
actions. Deny is destructive-styled. The notification body shows the
client-supplied name, icon, app and version and nothing else — no fingerprint,
per §4.4 — every field rendered as plain text with a length cap, since all of it
is attacker-controlled. The body should not read as an identification; "a device
calling itself X wants to connect" is the honest phrasing.

Authorization for notifications is requested at first launch during onboarding,
not lazily at the first connection, so the first pairing does not silently fail
to prompt.

### 6.4 TCC — the gotcha

**The daemon needs its own TCC grants.** Consent is per-executable, so the
approval the user grants to `IrohServer.app` does not cover
`irohd`. If the daemon is the first to touch `~/Documents`, the prompt names a
process the user has never heard of, or — for a non-GUI-session process — no
prompt appears at all and the call just fails with `EPERM`.

Handling:

- Directory selection happens in the **app**, via `NSOpenPanel`. The app holds
  consent, mints a security-scoped bookmark, and passes the bookmark (not the
  path) to the daemon over XPC.
- The daemon resolves the bookmark and calls
  `startAccessingSecurityScopedResource` before use.
- Both binaries carry the same TCC-relevant usage description strings and are
  signed with the same Team ID.
- On first share, the app performs a probe read to force any prompt to appear
  while the user is looking at a file picker and the request makes sense.
- Settings shows a per-share health indicator, with a "Repair access" button
  that re-runs the picker when a bookmark has gone stale or consent was
  revoked in System Settings.

### 6.5 Settings

Identity (full `EndpointId`, its 6-character fingerprint, and reset identity —
there is no rotate action, per §4.3) · Sharing (the pairing-window restriction of
§4.4 and its window length, auto-deny timeout, max connections) ·
Network (relay: n0 default or custom URL, direct-only toggle) · Devices (resolve
locations on/off, with the database's attribution notice and version shown) ·
Notifications (global DND, per-event toggles) · Storage (blob cache size and
location, clear cache) · Startup (register/unregister the login agent) ·
Updates (channel, check now) · Advanced (log level, export audit log).

The location toggle is on by default and reversible: switching it off clears
every stored `Device.location` immediately rather than merely hiding the
column, so the setting means what it says.

---

## 7. Packaging, startup, and updates

### 7.1 Bundle layout

```
IrohServer.app/Contents/
  MacOS/IrohServer                                   (Swift, SwiftUI + AppKit)
  Library/LaunchAgents/dev.irohserver.daemon.plist
  Resources/irohd                                    (Rust, universal binary)
```

Both binaries hardened-runtime signed with one Developer ID, the bundle
notarized and stapled, shipped as a signed DMG. `irohd` is built
`aarch64-apple-darwin` + `x86_64-apple-darwin` and `lipo`'d, so one download
covers both architectures.

### 7.2 Registration

`SMAppService.agent(plistName:)` (macOS 13+), registered from the app during
onboarding after an explicit opt-in — never silently. The plist sets
`RunAtLoad` and `KeepAlive` with `SuccessfulExit=false`, so launchd restarts
the daemon if it crashes but respects a deliberate stop. Unregistering from
Settings both unloads the agent and stops it.

`SMAppService.status` is polled on app launch, because the user can disable the
agent in System Settings → General → Login Items, entirely outside our app.
That state must be reflected honestly in the UI rather than assumed.

### 7.3 The honest availability statement

Because this is a user agent, sharing resumes **at login**, not at boot. A Mac
that reboots to the login window is not serving. Settings says this in plain
words next to the startup toggle. Pretending otherwise would produce silent
unreachability that is very hard for a user to diagnose.

### 7.4 Updates

Sparkle 2, appcast over HTTPS, EdDSA-signed. Sparkle replaces the whole bundle
— including `Resources/irohd` — while the *old* daemon is still running from
the replaced file. So the update is not complete until the daemon restarts.

Flow:

1. App and daemon exchange versions on every XPC connect
   (`daemonVersion()`), and the app compares against its own.
2. On mismatch the app sends `prepareForRestart()`. The daemon stops accepting
   new connections, lets in-flight transfers drain up to 30s, persists state,
   and exits cleanly.
3. launchd restarts it from the new binary (`KeepAlive`), and the app waits for
   the version handshake to come back matching.
4. If the mismatch persists after two attempts, the UI surfaces it rather than
   looping.

A daemon that finds itself older than the app's expected protocol version
refuses to serve and reports `NeedsRestart`, so a half-updated install fails
loudly instead of serving with stale logic.

**Sparkle and the running agent.** Sparkle's installer will want to terminate
the app; the agent is a separate process and will not be terminated for us.
Step 2 exists precisely to cover that gap, and must run *before* Sparkle's
relaunch, via `SPUUpdaterDelegate`.

---

## 8. Threat model, quotas, and audit

### 8.1 What we defend against

| Threat | Mitigation |
|---|---|
| Stranger discovers the `EndpointId` and dials | No grant → connection closed at HELLO, no metadata disclosed |
| Invite code intercepted or forwarded | Confers only the right to ask; Accept is still required and requests are rate-limited (§4.3). Not revocable — §8.2 |
| Invite code leaks widely — group chat, screenshot, wiki | Partial: the pairing-window restriction (§4.4) and rate limiting (§8.3) absorb the knocking. There is nothing to rotate (§4.3) |
| Denied device keeps knocking with its permanent code | Deny and block pins the `EndpointId` to a blocklist checked first in §4.4 |
| Attacker guesses an `EndpointId` in order to dial | 256 uniformly random bits, not enumerable — this is the whole reason holding a ticket means anything (§4.3) |
| Malicious client reads outside a share | Path confinement re-checked per request on the resolved path (§5.4) |
| Malicious client probes for file existence | `PermissionDenied` and `NotFound` are indistinguishable (§5.5) |
| Forgotten device reuses an old ticket | Identity is the credential; revocation is immediate (§4.7) |
| Device lies about its name, icon or app version | Descriptor is untrusted by construction; identity is the fingerprint, never the name (§4.2) |
| Device name carries bidi overrides or control characters to disguise itself | Sanitised and capped on arrival, before storage or display (§4.2) |
| Device masks where it is with a VPN, Tor, or corporate egress | Not defended, and not treated as a control: location is display-only and never gates authorization (§4.2) |
| Peer IPs leak to a geolocation provider | Resolution is local against a bundled database; no geo API is ever called (§4.2) |
| Local malware drives the daemon over XPC | Peer code-signature validation pinned to Team ID (§2.3) |
| Resource exhaustion | Quotas, §8.2 |

### 8.2 What we explicitly do not defend against

- **A compromised client device.** A stolen laptop keeps its grants until it is
  forgotten. Mitigation is human, and the device list is what makes it
  actionable: presence and last-seen show whether the thing is still being
  used, and Forget is one click from that row.
- **A ticket substituted in transit, or simply forwarded.** Nothing in pairing
  authenticates *which* device is knocking. There is no out-of-band verifier on
  the code (§6.1) and no fingerprint on the Accept prompt (§4.4), so an attacker
  who replaces the code in a channel they control presents at the prompt exactly
  what the invited device would have. The Accept gate confines pairing to moments
  a human chose; it does not establish who was at the other end. The mitigation
  is procedural: send the code over a channel you trust.
- **A leaked ticket, after the fact.** With no token to rotate (§4.3), a code
  that has circulated stays valid as long as the identity does. Blocking
  endpoints individually and closing the pairing window are the available
  responses; resetting the identity is the only complete one, and it costs every
  existing pairing (§3.2).
- **The Mac's own user.** Anyone with the login session can read the state DB.
- **Traffic analysis by the relay.** A relay sees encrypted bytes and endpoint
  IDs. It cannot read content, but it observes that two endpoints are talking
  and roughly how much. Self-hosting a relay (§6.5) narrows this.

### 8.3 Quotas

Per-device and global, enforced in the daemon: max concurrent connections
(default 8 global, 3 per device), max concurrent transfers, bandwidth ceiling
(default unlimited, configurable), max request rate, and a cap on pending
pairing requests (§4.5). Exceeding a limit returns `QuotaExceeded` rather than
dropping the connection, so a well-behaved client can back off.

Failed pairing attempts from one `EndpointId` are rate-limited with exponential
backoff, and repeated denials add it to a local blocklist.

**These limits carry more weight here than in a design with expiring or
revocable invitations.** A permanent, unrevocable code means the set of parties
who can request pairing only ever grows, with no rotation available to shrink it
again, so rate limiting and the blocklist are the primary defence against
pairing-request abuse rather than a backstop behind a TTL. Treat a regression in
either as a security bug, not a polish item.

### 8.4 Audit log

Append-only, in redb, capped by age and size, exportable as JSONL from
Settings. Records: pairing accepted/denied, device paired/forgotten, device
descriptor changed (old and new name, app and version), grant changed, share
added/removed, connection opened/closed, and every mutating operation
(`WRITE`, `DELETE`, `RENAME`, `MKDIR`) with device, share, path, size, and
outcome. Every entry carries the `EndpointId` fingerprint rather than only the
name, so the log stays meaningful after a device renames itself.

**Location is deliberately absent from the log**, and so are peer IP addresses.
The log records that a device connected, never from where. Adding either would
convert an access log into a movement history for every paired device, which is
a different and much more sensitive artifact than the one this section
describes — and it would survive export, so it could not be walked back. Reads are logged at aggregate level only (count and bytes
per session) to keep the log from becoming its own surveillance problem.

---

## 9. Testing strategy

**Rust core.** The valuable property here is that two `iroh::Endpoint`s can be
bound in one test process and connect to each other directly, with no relay and
no network. So the entire protocol — pairing, grants, reads, writes, path
confinement — is testable as fast in-process integration tests, not as an
awkward multi-machine ritual. This is the backbone of the suite.

Specifically:

- Path confinement gets a dedicated adversarial table: `..` traversal, absolute
  paths, symlinks out of the root, symlink swapped between calls (TOCTOU), NFC
  vs NFD, empty components, very long paths, null bytes.
- Authorization gets an exhaustive matrix: every `Rights` combination against
  every operation, asserting both the allow and the deny path — a permission
  test that only checks the allow side proves nothing.
- Pairing: an unknown endpoint prompts and is rate-limited on repeat; approval
  timeout; revocation mid-transfer. With the pairing-window restriction of §4.4
  enabled, an unknown endpoint arriving outside an open window is closed with no
  error detail, and the same endpoint inside one prompts — the two cases must be
  driven by the same fixture so the toggle is what differs.
- A blocklisted `EndpointId` is refused before the descriptor is read, and stays
  refused across a daemon restart.
- A ticket connects using only the relay named inside it, with discovery
  unavailable — the test that proves the ticket is genuinely self-sufficient for
  first contact.
- A minted ticket carries **no** direct addresses, asserted on an endpoint whose
  address set is populated. This is the one property of §4.3 that a
  correct-looking implementation loses silently, so it is worth an explicit test
  rather than an inspection.
- A self-hosted relay URL round-trips through the ticket, and a ticket carrying
  one connects.
- Descriptor handling gets its own adversarial table, since every field is
  peer-supplied: over-length name, control characters, bidi overrides, invalid
  UTF-8, NFD input, an unknown `form_factor` decoding to `Unknown`, a descriptor
  changing between reconnects, and two devices claiming an identical name —
  asserting in the last case that both stay distinguishable by fingerprint.
- Presence: `last_seen_at` advances on disconnect and never from a
  client-supplied value; a keepalive timeout marks the device offline;
  simultaneous connections from one device report as a single `Online` with a
  connection count, not as two devices.
- Location resolution, which is mostly a table of refusals: a relay-only
  connection must yield `Unavailable` and must **not** report the relay's
  city; RFC1918, CGNAT, link-local, loopback and IPv6 ULA/link-local addresses
  yield `LocalNetwork`; a public address absent from the database yields
  `Unavailable`, not a nearest guess; a relay-only connection that gains a
  direct path re-resolves; disabling the setting clears stored locations. The
  relay case is the one worth writing first — it is both the easiest to get
  wrong and the one that produces plausible-looking bad data.
- An assertion that no audit-log writer emits a location or an IP address, so
  the §8.4 guarantee cannot regress silently.
- The Invite screen's three states (§6.1) are all drivable from a fake daemon,
  Unavailable included, so the first-run failure path can be exercised without
  breaking a real install.
- A generated QR is decoded back within the test and asserted equal to the
  ticket that was issued. A ticket that encodes a truncated or stale payload is
  otherwise invisible until a human scans it and the failure appears on somebody
  else's device.
- The invite code is stable: reading it twice, across a daemon restart, returns
  the identical string.
- The entry field's contract, which is deliberately thin: a ticket round-trips
  through parse and serialise; surrounding whitespace and newlines picked up from
  a clipboard are tolerated; and a truncated ticket, a ticket with a single
  character substituted, and text that is not a ticket at all are each rejected
  *locally*, with no network attempt.
- Write integrity: declared hash not matching fetched bytes must leave *no*
  file at the destination.

**XPC layer.** The daemon's service is exercised through a real
`NSXPCConnection` in a test harness, including the code-signature rejection
path. Swift-side, the app codes against a protocol so the UI can be driven by a
fake.

**End-to-end.** A small Rust reference CLI client, built as a test binary,
drives a real daemon over a real (loopback) iroh connection. This doubles as
the executable specification of the protocol for whoever writes the companion
app.

**Manual, unavoidably.** TCC prompts, notification actions, Sparkle updates,
and login-item registration cannot be meaningfully automated. Each gets a
written checklist run before release.

---

## 10. Milestones

| # | Deliverable | Done when |
|---|---|---|
| **M0** | Build gate | App + daemon build, sign, and complete an XPC version handshake; peer validation rejects an unsigned caller. No user-visible surface |
| **M1** | **Invite screen** | Identity generated in the Keychain, endpoint binds, the `EndpointTicket` reaches the app over XPC carrying a relay and no direct addresses; rendered as copyable text, its QR, and all three states of §6.1. Nothing else on the screen. The first screen shipped |
| **M2** | Pairing & devices | A device scans the M1 ticket and completes pairing: Accept/Deny notification, device list with icon, name, app version, location and live presence, Forget. No file access yet |
| **M3** | Read-only shares | Directory picker → bookmark → daemon; `LIST`/`STAT`/`READ` with blobs fetch; full path-confinement suite green |
| **M4** | Writes | `WRITE` via reverse fetch, atomic install, hash verification; `MKDIR`/`DELETE`/`RENAME`; grant matrix green |
| **M5** | Shell | Menu-bar badge, Settings including the endpoint ID and the pairing-window restriction, DND/mute/pause, quotas, audit log |
| **M6** | Ship | Notarized DMG, Sparkle appcast, `SMAppService` registration, update-restart dance, manual checklist |
| **M7** | Companion client | Reference CLI hardened into the first real client app |

M1 is deliberately a vertical slice rather than a layer. The Invite screen is
worth building first precisely because it cannot be built without a signed pair
of binaries, Keychain access, a bound endpoint and a working XPC contract all
functioning together — so it converts the four assumptions most capable of
invalidating this design into observed facts, behind a screen you can actually
look at. M0 is the build gate underneath it and has no UI, so it does not
compete for "first screen".

M0–M2 remain the risky part, front-loading every macOS integration question
(signing, entitlements, Keychain, XPC) before any file-sharing code exists.

---

## 11. Risks and open questions

**iroh-blobs is pre-1.0 while iroh core is 1.1.** `iroh-blobs 0.103.0` states
in its own documentation that it "is not yet considered production quality,"
and its minor versions have been breaking. We depend on it for all bulk
transfer. Containment: confine every blobs call behind our own `BlobStore`
trait in the daemon, so a version bump — or a fallback to plain QUIC streams
(the rejected approach B) — is one module, not a rewrite. Pin exact versions
and upgrade deliberately.

**At-boot availability.** §2.2 accepts login-time start. If serving from a
cold, unattended reboot ever becomes a requirement, the answer is a
`SMAppService.daemon` running as root — which then cannot use the login
keychain or hold TCC grants, and would need its own key storage in a
`root`-owned file and shares confined to non-TCC-protected paths. That is a
different design, not a setting. Flagging it now so the decision is not
discovered late.

**Relay dependence.** Default n0 relays are a third party in the availability
path (not the confidentiality path). Self-hosting is exposed in Settings but
untested at this stage.

**Published discovery is optional, and remains a disclosure.** Carrying the
relay inside the ticket (§4.3) removed the hard dependency this section
previously recorded: a ticket connects on the strength of its own relay, so
pairing does not break when discovery is unavailable. What publishing buys is
robustness for the one way a ticket can still go stale — a relay that has moved
or been retired — and with rotation gone it is the only recovery for that case
short of resetting the identity. That is enough to keep it on by default.

The disclosure is unchanged: anyone holding the `EndpointId` can resolve whether
this endpoint exists and roughly where to reach it, at any time, without our
knowing. With a permanent, unrevocable ticket expected to circulate, treat that
as the standing condition rather than an edge case. Declining to publish is still
a legitimate setting to offer; the cost is that a user whose relay changes has no
way to reach the devices holding their old ticket.

**Open — not blocking M0–M3:**

1. Blob cache eviction policy: LRU by size is assumed; whether a hot share
   should be pinned is unresolved.
2. `WATCH` semantics on large directory trees — FSEvents coalescing may make
   precise per-file events impractical; may degrade to "something under this
   path changed."
3. Whether the companion client should be Swift (shared model code, Apple-only)
   or Rust core + thin shells (portable, more work). Deferred to M7.
4. Whether devices should ever be groupable under a person. §4.2 argues no for
   now — per-device grants are the point. If the list routinely exceeds a
   dozen rows the calculus changes, and the migration would be additive: a
   nullable `owner_id` on `Device`, with grants staying per-device.
5. Whether `form_factor` should carry `Watch` and `TV` variants now. `Unknown`
   already renders them safely, so the decision can wait for a client that
   actually reports one.
6. Which geolocation database to bundle, and therefore what attribution the
   app must carry and how much it adds to the download. City-level is assumed;
   if the bundle cost is unwelcome, country-only precision is a legitimate
   product answer rather than a degradation, since §4.2 already renders
   `Country` as a first-class case.
7. Whether pairing needs any device authentication beyond the Accept gate. §4.4
   deliberately has none — no token, no fingerprint on the prompt, no
   out-of-band check — which is the consequence of removing every value a human
   was expected to read or recite. If field use shows people accepting prompts
   they cannot account for, the cheapest addition is a short verification string
   derived from the *connection* and shown identically on both ends: it
   authenticates the channel, is compared visually rather than dictated, and
   reintroduces no secret and no rotation.
7. Multiple Macs under one identity is out of scope, but if it ever arrives,
   the identity model in §3 is the thing that has to change first.

---

## Appendix: pinned versions

| Dependency | Version | Verified |
|---|---|---|
| `iroh` | 1.1.0 (2026-08-25) | 2026-08-30 |
| `iroh-blobs` | 0.103.0 (2026-06-15) | 2026-08-30 |
| `iroh-tickets` | tracks `iroh` 1.x | 2026-08-30 |
| Geolocation database | undecided — see §11, item 6 | — |
| macOS deployment target | 13.0 (`SMAppService`) | — |
| Sparkle | 2.x | — |

Naming note for anyone reading older iroh material: `NodeId`, `NodeAddr`, and
`NodeTicket` were renamed to `EndpointId`, `EndpointAddr`, and `EndpointTicket`
in iroh 0.94. Tutorials predating that use the old names throughout.
