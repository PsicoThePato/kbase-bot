# Running a Federation Instance

An operator's guide to connecting two (or more) KbaseBot instances. For the
protocol design and its rationale, see
[`multiplayer-federation.md`](multiplayer-federation.md); this doc is the
practical path from a single-user bot to a working peer pair.

## What federation gives you

Your bot and a friend's bot exchange questions, discussions, and published
items — under grants you issue explicitly, scoped to labeled slices of your
knowledge base, revocable at any time. The safety model in one paragraph:
peer-authored bytes never enter your bot's main conversation loop. Every
interaction with a peer runs in a confined subagent that holds a fixed,
minimal toolset and sees the knowledge base only at that peer's clearance.
Anything a peer pushes to you lands in a quarantine inbox that you review and
promote or discard yourself. Deny is the default everywhere: adding a contact
grants nothing, unlabeled files are `private`, and `private` can never be
granted.

## Try it without any setup

```sh
mix kbase_bot.demo
```

Boots two instances (Alice and Bob) on localhost with a deterministic LLM
stub — no API keys — and walks through cards, grants, query/answer, key
rotation, and store-and-forward delivery across a peer restart.

## Setting up a real instance

### 1. Generate an identity

```sh
mix kbase_bot.gen_identity /path/to/identity.json
```

Creates an Ed25519 keypair (file mode 0600). Your principal id is the
SHA-256 fingerprint of the public key. Back this file up; it *is* your
federation identity.

### 2. Configure the environment

```sh
FEDERATION_ENABLED=true
FEDERATION_KEY_PATH=/path/to/identity.json
FEDERATION_PORT=4040                          # Bandit HTTP listener (default 4040)
FEDERATION_PUBLIC_URL=https://your-host:4040  # advertised in your contact card
FEDERATION_DISPLAY_NAME=YourBotName
```

Both flags matter: `FEDERATION_KEY_PATH` makes the ~27 owner-facing federation
tools visible to the manager, and `FEDERATION_ENABLED` starts the inbound HTTP
endpoint (`POST /federation/inbox`) and the outbound delivery queue.

Networking notes:

- The listener speaks plain HTTP; for a public deployment put it behind a
  TLS-terminating reverse proxy (Caddy, nginx) and advertise the `https://`
  URL. Envelopes are signed end-to-end, so transport is not part of the trust
  model, but TLS still hides metadata.
- Open the port in your firewall. The NixOS module has `federationPort` +
  `openFirewall` options for this.
- Outbound requests refuse private/loopback/link-local addresses (SSRF
  guard). `FEDERATION_ALLOW_PRIVATE_ENDPOINTS=true` disables that guard for
  local multi-bot testing — never set it in production.

### 3. Exchange contact cards

In your bot's chat: ask for your card (`show_federation_card`). You get a
signed JSON blob whose endpoint is derived from `FEDERATION_PUBLIC_URL`. Send
it to your friend over any channel you already trust (the card is public
information — it holds your display name, endpoint, and public key, and is
self-signed, so it cannot be forged, only replayed). Your friend pastes it
into their bot (`add_contact`), and you do the same with theirs. Cards are
sequence-versioned; a stale card is rejected in favor of a newer one already
held.

Adding a contact grants nothing. It only teaches your bot who the peer is and
how to verify their signatures.

### 4. Label your knowledge base

Grants refer to **scopes**, and files carry scopes two ways:

- Frontmatter, per file: `scopes: [training]`
- Path defaults, per directory tree: a `.kbase-policy.yml` at the KB root
  mapping globs to scopes (most specific pattern wins):

```yaml
defaults:
  "training/**": {scopes: [training]}
  "recipes/**": {scopes: [recipes]}
  "medical/**": {scopes: [medical]}

non_grantable:
  - medical
```

A file with no label is `private`. A peer can read a file only if **every**
scope the file carries is covered by a live grant to them (intersection
semantics), and `private` — plus any scope you list under `non_grantable` —
can never be granted at all.

### 5. Issue grants

Always preview first: `preview_grant` shows exactly which files a scope grant
would expose to a given peer before you commit. Then `grant_scope` issues a
signed delegation record for capabilities among `query`, `read`, `subscribe`,
`discuss` (optionally with an expiry). Judge blast radius accordingly: a
`query` grant already lets the peer's answers **quote file contents
verbatim**; `read` only adds direct file access on top. Grants go to a single principal or to
`circle:<name>` — circles are named groups you manage with `edit_circle` /
`list_circles`.

Bookkeeping tools: `list_grants`, `revoke_grant`, and `review_disclosures`,
which audits what was actually sent to whom, per peer and scope — the answer
to "what does Alice's bot know about me by now?".

## Day-to-day use

- **Ask a peer something**: `query_peer`. A confined subagent on their side
  answers at your clearance; the reply arrives in your chat. Check what
  they've granted you first with `list_peer_scopes`.
- **Longer exchanges**: `discuss_peer` with a mission (e.g. "get her bread
  recipe and file it"). The discussion runs subagent-to-subagent, bounded in
  turns, and results land in your quarantine inbox, not your KB.
- **A peer's bot escalates a question** their grants can't answer: the
  escalation appears in your chat with an exchange id; answer it with
  `answer_escalation`.
- **Feeds**: `subscribe_peer` to a scope a peer granted you; their
  `publish_item` pushes land in your inbox. `bind_topic` maps their scope
  names onto yours so searches line up.
- **Review the inbox**: `review_inbox`, then `promote_inbox_item` (moves the
  file into your KB, still `private` and attributed to its source until you
  relabel it) or `discard_inbox_item`. Each verdict is recorded as a trust
  signal for that peer and topic — raw material for future automated trust.
- **Bookkeeping**: every listed action has its inverse and its list —
  `list_contacts`, `list_subscriptions` / `unsubscribe_peer`,
  `list_bindings` / `unbind_topic`, and `show_trust_signals` for the verdict
  history per peer.

## Limits and protections you get for free

- Per-peer monthly inference budget (`FEDERATION_PEER_MONTHLY_BUDGET`,
  default 100 LLM loops); past it the peer receives a rate-limited decline.
  Your own actions are never budgeted.
- Inbound rate limits (per IP and per principal), a freshness window that
  rejects envelopes older than 7 days or from the future, and replay
  protection on envelope ids.
- The inbound endpoint always answers 204, so authorization outcomes leak
  nothing.
- Offline peers: outbound envelopes queue with exponential backoff for up to
  7 days; you get one alert if a peer stays unreachable past
  `FEDERATION_UNREACHABLE_ALERT_DAYS` (default 3).

## Key rotation

`rotate_identity` (requires an explicit confirmation) generates a fresh
keypair, signs a rotation proof with the old key, re-signs your live grants,
and broadcasts the new card to every contact — queued for any peer currently
offline. Rotation is single-hop: a peer who missed one rotation catches up
from the proof carried in your card, but a peer two rotations behind must
re-add you manually. If you rotate because the old key was *compromised*,
tell your peers out-of-band too: an attacker holding the old key can sign a
rotation just as well as you can.

## Troubleshooting

- **Federation tools don't appear in the bot** — `FEDERATION_KEY_PATH` unset
  or unreadable.
- **Peer can't reach you** — check `FEDERATION_ENABLED=true`, the port is
  open, and the card's endpoint URL matches what the proxy actually serves;
  re-share your card after changing `FEDERATION_PUBLIC_URL`.
- **`query_peer` returns a decline** — either no grant covers the scope, the
  scope doesn't exist, or you hit their peer budget. Declines are
  deliberately indistinguishable between "no grant" and "no such scope";
  budget declines say so.
- **Deliveries pending** — `list_pending_deliveries` shows the queue and
  per-peer backoff state.
