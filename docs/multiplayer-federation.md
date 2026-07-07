# Multiplayer / Federation Design

Status: **design — not implemented**. This doc defines the protocol concepts and the
preparation work in the current codebase so that federation can be added later without
a rewrite.

## Vision

My knowledge base should be able to talk to my friends' knowledge bases:

- **Agent ↔ agent**: my agent asks a friend's agent a question ("what movies did João
  like recently?") and gets an answer scoped to what that friend chose to share with me.
- **Agent ↔ human**: a friend's agent (or the friend directly) can surface a question
  *to me* via my bot, and I answer as a human. Symmetrically, my agent's question may be
  escalated to my friend when their agent can't answer.
- **Privacy**: I control exactly which parts of my knowledge base are surfaceable to whom.
  Deny by default.
- **Trust**: per-friend, per-topic. I trust Alice on movies but not on nutrition. When my
  agent aggregates opinions, it weighs sources accordingly.
- **Transitivity (opt-in)**: if Alice trusts Carol on movies and I marked my movie-trust in
  Alice as transitive, my agent may reach Carol's recommendations *through* Alice, even
  though I don't know Carol.
- **Pluggable identity**: how a peer proves who they are is decoupled from everything else.
  Different peers may require different identity providers.

## Protocol vs. implementation

These are two deliberately separate artifacts:

- **The protocol** — identity assertions, signed envelopes, contact cards, scopes/grants
  semantics, delegation-record proofs. Implementation-agnostic: nothing in it names Elixir,
  Telegram, HTTP, or a queue. Anyone could implement a compatible peer in any stack.
- **KbaseBot's implementation** — how *this* bot speaks the protocol: which transports it
  listens on, where contacts/grants/trust are persisted (SQLite/policy files), how
  escalation surfaces in Telegram.

The forcing function for the split: **the protocol is transport-agnostic.** I might accept
HTTPS POSTs on a port; a friend's agent might only consume from a RabbitMQ queue; someone
else might poll an inbox. Envelopes are signed, so the delivery channel needs zero trust —
any pipe that moves bytes is a valid transport. What the protocol standardizes is the
envelope format and the **contact card** that advertises which pipes a peer accepts.

## Core concepts

Everything hangs off six nouns:

| Concept | What it is |
|---|---|
| **Principal** | A stable identity for a person-or-agent pair. Canonical form: a public-key fingerprint plus display metadata. The owner is a principal too (the superuser). |
| **Contact** | The owner-side record of a known peer: a principal plus its current contact card (endpoints, accepted identity providers), a human-friendly name, and links to its grants and trust entries. The address book. |
| **Scope** | A label attached to knowledge (`movies`, `training`, `medical`). Content carries scopes; grants are expressed against scopes, never against raw paths. Scope names are **recipient-local**: on the wire they always refer to the answering peer's namespace. |
| **Grant** | A **signed delegation record** `{iss, aud, scope, caps, caveats, sig}` — what a principal may *do*: `query` (ask questions answered from that scope), `read` (see excerpts), `subscribe` (standing feed), `discuss` (open threads). Every capability carries a **`depth`**: how many further delegation edges may follow it (default 0 — not delegable). The owner's grants table is simply the set of records where `iss` = owner; peers author the same shape when they delegate. |
| **Trust** | `(principal, topic, weight, transitive?)` — how much the owner's agent should *believe* that principal on a topic when aggregating answers. Topics are the owner's own private labels for domains of belief; they never travel on the wire. |
| **Provenance** | The signed chain of principals an answer travelled through (`me ← alice ← carol`), carried on every federated response. |

**Privacy and trust are orthogonal.** Privacy governs what leaves my vault (grants);
trust governs how incoming information is weighted (trust records). They live in
separate tables and fail independently — and they use two different vocabularies that
happen to look alike:

- A **scope** gates *content*, and is meaningful in the namespace of whoever's vault it
  labels: when my agent queries Alice's `movies`, that string is Alice's label, learned
  from her scope advertisement (below). My own scopes gate my own vault.
- A **topic** names a *domain of belief* in my own private vocabulary. My agent assigns
  a topic to every question it composes ("this is a movies question") and scores the
  returning answers with `trust(peer, topic)` — regardless of which scope string rode
  the wire. Topics never leave my agent, so they never need cross-peer translation.

The two meet in exactly one place — the **binding table** (see "Scope bindings — the
translation layer"): owner-private rows mapping my topics to specific peers' scope
labels, consulted at query-composition and subscription time.

## Identity module

A behaviour, so providers are swappable and peers can each demand a different one:

```elixir
defmodule KbaseBot.Identity.Provider do
  @callback id() :: atom()                     # :ed25519, :did, :telegram, :psk
  @callback challenge(peer_hint) :: challenge
  @callback verify(assertion, challenge) :: {:ok, Principal.t()} | {:error, term()}
end
```

- A **Principal** is minted by a provider but stored provider-agnostically:
  `%Principal{id: "sha256:...", provider: :ed25519, display_name: "Alice", meta: %{}}`.
  Grants and trust attach to `Principal.id`, never to transport details.
- **First provider to build: Ed25519 keypairs.** (age keys are X25519 — encryption-only,
  they cannot sign; age stays for vault encryption.) A peer's identity is their public
  key; requests are signed; verification is a signature check — OTP `:crypto` supports
  Ed25519 natively, so no infrastructure or dependency is needed. Cards and records
  carry the raw public key; the principal id is its sha256 fingerprint.
- Later candidates: DIDs + verifiable credentials (standards-track, good for
  friends-of-friends who share no direct channel), Telegram account attestation
  (low-security convenience tier), pre-shared secret (testing).
- Each peer entry records *which providers I accept from them* and vice versa. Two peers
  negotiate the intersection at handshake time.

The current Telegram auth gate (`kbase_bot/lib/kbase_bot/telegram/bot.ex:69-73`) becomes
just one provider: "matches owner chat id" → owner principal.

## Privacy: scopes, grants, enforcement

### Labeling content

Markdown frontmatter, extending the existing `name`/`description` convention
(`knowledge_base/user_profile.md:1-4`):

```yaml
---
name: Movie log 2026
description: Films watched and ratings
scopes: [movies]
---
```

Plus a repo-level policy file for path-based defaults, so 67 existing files don't need
immediate backfill:

```yaml
# knowledge_base/.kbase-policy.yml
defaults:
  "Journal/**":  {scopes: [journal]}
  "medical/**":  {scopes: [medical]}
  "**":          {scopes: [private]}      # unlabeled ⇒ private, always
grants:
  "sha256:alice…": {movies: {query: {depth: 2}, subscribe: {}}, books: [query, read]}
  "sha256:bob…":   {training: [query]}        # list form ⇒ all capabilities at depth 0
```

Rules:

- **Deny by default.** No scope match + no grant ⇒ the content does not exist for that
  principal. `private` is a reserved scope no grant can name.
- **Multiscope = intersection (most restrictive wins).** Content may carry several
  scopes; a principal may access it only with the capability on **every** scope it
  carries — a principal reaches exactly the files whose scope set ⊆ their granted
  scopes (`Policy.filter` and the QMD post-filter are a subset check). Adding a scope
  never widens access.
- **Escalation is just another scope.** `scopes: [pop, private]` keeps a file topically
  filed under `pop` while `private` (ungrantable) makes it federation-invisible — a
  per-file kill switch with no extra mechanism. Ad-hoc compartments work the same way:
  `[pop, inner-circle]` is readable only by principals holding both. (The classic
  MLS-compartment lattice.)
- `medical` (and anything the owner flags) is **non-grantable**: the policy loader
  rejects grants against it. This encodes the existing CLAUDE.md rule that health data
  never leaves the vault.
- The `grants:` entries are authoring sugar: the loader materializes each as a
  **signed delegation record** with `iss` = owner — the same artifact peers exchange
  when they delegate (see "One authorization mechanism").

### Scope visibility & advertisement

Deny-by-default extends to scope *existence*: a principal can see exactly the scopes on
which they hold at least one grant. Whoever may query `medical` thereby knows a
`medical` scope exists; nobody else ever learns that. Grossly inspired by A2A's split
between the public AgentCard and the authenticated extended card:

- The **contact card** may carry a `scopes` field listing only *publicly* visible
  scopes — those granted to the `anyone` pseudo-principal. Cards are self-signed and
  relayed through untrusted channels, so nothing per-viewer can live in them.
- The per-principal view is fetched over the wire: `LIST-SCOPES` → `SCOPES {scopes:
  [{name, description?}]}`, answered after signature verification and filtered to the
  asker's grants. Descriptions exist for the requester's *binding* step (below) —
  matching on bare names is guesswork. This is also how a sender learns the
  recipient-local labels it may put in a `QUERY`.

### Scope bindings — the translation layer

Peers name their scopes in their own vocabulary; I think in mine. Alice's `medical`
and Bob's `saude` are both, to me, `health`. A **binding** is an owner-private row:

```
(my_topic, principal, peer_scope, confidence, confirmed?)
  health → alice: medical     (0.95, auto)
  health → alice: fitness     (0.80, auto)
  health → bob:   saude       (—,    owner-confirmed)
```

- **Populated when a peer's `SCOPES` answer arrives**: the agent matches names and
  descriptions against my topic vocabulary (an LLM-judgment step), auto-binds above a
  confidence threshold, and escalates ambiguity to Telegram ("Alice has a scope
  `wellness` — bind to your `health` topic?").
- **Everything owner-side reads through bindings**: query fan-out ("ask my
  health-trusted peers" resolves to alice:`medical` + bob:`saude`), subscriptions
  (subscribing to a topic subscribes to every bound scope), and trust scoring (an
  answer from alice:`medical` scores against `trust(alice, health)`).
- Bindings, like topics and trust, never cross the wire.

### Enforcement is structural, not prompt-level

The requesting principal rides in the tool context, and `read_file` / `list_files` /
`search_knowledge` filter **before** any LLM sees the content:

```elixir
KbaseBot.Policy.can?(principal, capability, resource) :: boolean
KbaseBot.Policy.filter(principal, capability, resources) :: resources
```

A peer's query must never be answered by an agent that had ungated vault access — the
answering task is spawned *with the peer as its principal*, so the tools themselves
refuse out-of-scope reads. Prompt instructions ("don't reveal X") are not a security
boundary; a remote agent's text is untrusted input (prompt injection is table stakes
here).

QMD note: the semantic index is global (`search_knowledge.ex:37`), so results are
post-filtered through `Policy.filter/3` until QMD grows scoped collections.

## Trust

Stored per peer, per topic:

```yaml
trust:
  "sha256:alice…":
    movies:    {weight: 0.9, transitive: true, max_hops: 2}
    nutrition: {weight: 0.2}
  "sha256:bob…":
    movies:    {weight: 0.4}
```

- **Weight** is advisory input to the *owner's* agent: when it aggregates federated
  answers ("find me movies my friends liked"), it weighs and attributes by source. It is
  never sent to peers — how much I trust Alice is itself private.
- Trust decays multiplicatively along provenance chains: an answer from Carol via Alice
  scores `trust(alice, movies) × alice_reported_confidence`, capped by `max_hops`.
- Answers always carry provenance, so the agent can say "Carol (friend of Alice) rated
  it 9/10" and I can decide what that's worth.

## Transitivity

Two different things, kept deliberately separate:

1. **Transitive querying** (my question travels): a query carries `ttl_hops`. If Alice's
   agent can't answer and my trust record marks movies as transitive, her agent may
   forward the question to *her* trusted movie peers, decrementing the TTL. My data never
   moves — only my question does (and the question text itself is something my agent
   composed for external ears). Two gates, one per side: *my* trust record's
   `transitive` flag governs whether my agent lets the question travel at all; on the
   *answering* side, a forwarded question is just a presented chain — Alice attaches an
   ephemeral attenuated record (`iss: alice, aud: me, query depth 0, short exp`) to the
   forward, and Carol's verifier requires her own record to Alice to carry `query`
   with `depth ≥ 1`. Same live-reachability rule as every access check — see "One
   authorization mechanism" below; hops never manufacture authority.
2. **Transitive access** (my data travels further): default **off**. When granted, no
   new artifact is needed: since a grant *is* a signed record, Alice delegates by
   authoring one — `{iss: alice, aud: carol, scope: movies, caps: {query: {depth: 0}},
   caveats: {exp: …}, sig}` — attenuating (never widening) what my record gave her,
   and handing it to Carol offline. Carol presents the chain when she queries; "One
   authorization mechanism" below defines how it is verified. Revoking Alice instantly
   severs everyone whose only path to me ran through her.

## One authorization mechanism

Direct and transitive access are not two systems. Every `QUERY` carries
`proof: [records…]`, possibly empty, and one verifier decides everything:

> Find a **live path** from me to the presenting principal covering
> `(scope, capability)`, over the union of **my local records** and the **presented
> ones**, where every edge's capability `depth` covers the remaining path length.

- **Direct peer**: `proof` is empty; the path has length 1 and is found entirely in my
  own table. Same verifier, degenerate case.
- **Transitive peer**: Carol presents `[alice→carol]`. The `me→alice` edge is *not*
  presented — it must exist, live, in my table. My local state is authoritative for my
  own edges; presented records only prove edges I couldn't know about. Delete my grant
  to Alice and Carol's record dangles from nothing — that is the whole revocation
  story for my side.
- **Depth replaces a separate `delegate` capability.** Every capability on a record
  carries `depth`: how many further delegation edges may follow it — **remaining
  hops, not distance from the owner** (default **0** — not delegable). In a path of
  length L (edges numbered 1..L outward from me), the record on edge i must carry
  `depth ≥ L − i`, and an attenuated record must carry a strictly smaller depth than
  its parent. Worked example:

  ```
  me    ──(query depth 2)──▶ Alice    Alice's budget: may delegate, ≤ depth 1
  Alice ──(query depth 1)──▶ Carol    Carol's budget: may delegate, ≤ depth 0
  Carol ──(query depth 0)──▶ Dave    Dave cannot delegate; chain (L=3) verifies:
                                      edge 1 ≥ 2 ✓, edge 2 ≥ 1 ✓, edge 3 ≥ 0 ✓
  ```

  Because the budget rides in the signed record itself, **delegation failure is
  locally decidable**: a holder at `depth: 0` knows offline, at authoring time, that
  any record they issue produces a chain no verifier will accept — and a presenter
  can check a chain's arithmetic before spending a round trip. Well-behaved agents
  never issue dead records; the verifier's `DECLINE` stays indistinguishable
  regardless. Depth is per capability, per grant — `query: {depth: 2}` next to
  `discuss: {depth: 0}` on the same scope is the expected shape: cheap capabilities
  may travel, expensive ones stay close (see Discussions for why this matters most
  there).
- **Caveats intersect along the path** (weakest link): the effective capability is the
  meet of every edge's caps, depth, and expiry. Hops never accumulate authority.
- **Inspectability is the point.** A proof is not an opaque blob; it is a list of
  human-readable, individually signed statements. "How did Carol come to see this?"
  is printing the path:

  ```
  me    ──(movies: query depth 2, issued 2026-07-01)──▶ Alice
  Alice ──(movies: query depth 0, exp 2026-08-01, issued 2026-07-03)──▶ Carol
  ```

  Proof and provenance are two instances of one shape — signed chains of principals:
  provenance is the path an *answer* traveled, a proof is the path *authority*
  traveled. Same inspection tooling; an owner-side `explain_access` tool falls out
  for free.
- **The honest asymmetry**: *my* revocations are instant (live table); *downstream*
  revocations are expiry-bounded — if Alice revokes Carol, I can't know until Carol's
  record expires. Delegated records must therefore be short-lived and re-issued. This
  is inherent to any offline-delegable scheme, so it is stated rather than hidden.

## Subscriptions

Standing feeds — the counterpart of Gossip's push-by-judgment. Capability:
`subscribe`, deliberately separate from `query`: answering a question is a bounded
disclosure; a subscription is a standing tap on everything new in a scope.

- `SUBSCRIBE {scope}` registers the feed (verified like any capability exercise —
  proof chain, live path, depth). `PUBLISH {scope, item, provenance}` delivers;
  `UNSUBSCRIBE` ends it. *When* a publisher pushes — every write, batched, curated —
  is publisher-local policy, not protocol.
- Authorization runs both ways through the one mechanism: the publisher honors a
  subscription only while a live `subscribe`-capable path covers the subscriber
  (revoking the grant kills the feed at the next check); the subscriber ingests a
  `PUBLISH` only if it correlates to a subscription it initiated — the initiator rule.
  Unsolicited `PUBLISH` correlates to nothing and drops.
- Incoming items run through the **same evaluator and quarantine discipline as
  Gossip**: a constrained task whose only write capability is appending to the inbox
  (`inbox/<topic>/…`, attributed frontmatter); promotion into the KB is an owner
  action. Subscribe and gossip differ only in trigger — a feed versus the peer
  agent's per-item judgment. The owner's accept/promote/discard actions on both are
  the labeled signal the future recommendation policy trains on.
- Bindings apply: "subscribe me to Alice's health stuff" resolves through the binding
  table to every peer scope bound to my `health` topic.

## Discussions

`QUERY`/`ANSWER` is one-shot. Some exchanges need turns — clarification ("which
João?"), negotiation, two agents narrowing something down together. Capability:
`discuss`.

- A discussion is a **thread**: opened by the first `SAY` (which names a scope and
  passes the one-verifier check for `(scope, discuss)`), continued by `SAY`s
  correlated by `thread`, ended by either side's `CLOSE` — or implicitly by turn cap
  or timeout. Async like everything else: turns may arrive hours apart, over
  different transports.
- A thread is pinned at open time to `(principal, scope)`. No mid-thread scope
  change — open another thread.
- **Peer-initiated threads run in a conversational federation responder**: the same
  fixed toolset (policy-filtered reads, `answer_peer`/`decline`/`escalate_to_owner`),
  the same fan-out cap, plus a **turn budget** — `min(owner default, grant's
  max_turns caveat)`. Each inbound `SAY` resumes the same bounded task; turns never
  accumulate capability.
- **Why depth matters most here.** Every peer-initiated turn is LLM inference the
  *answering* owner pays for. A `QUERY` costs one bounded task; a discussion
  multiplies that by turns; a *transitive* discussion multiplies it by strangers.
  `discuss` therefore ships at the default `depth: 0` — only direct peers can open
  threads — and delegating it should be rare, shallow, and short-lived.
  Per-principal rate limits apply as everywhere.

## Contacts & discovery

### Contact cards (protocol)

A peer's reachability is described by a **contact card**: a signed, versioned document
the peer authors about itself. Because it is signed by the peer's own key, it can be
obtained or relayed through *any* channel — pasted in a chat, fetched from a URL,
forwarded by a mutual friend — without trusting that channel.

```json
{
  "principal": "sha256:alice…",
  "display_name": "Alice",
  "seq": 7,
  "identity_providers": ["ed25519", "did"],
  "endpoints": [
    {"transport": "https", "address": "https://kb.alice.dev/inbox", "priority": 1},
    {"transport": "amqp",  "address": "amqp://mq.alice.dev/kbase_inbox", "priority": 2}
  ],
  "sig": "…"
}
```

- `endpoints` is an ordered list of `{transport, address, params, priority}`. Transport
  names are an open set (`https`, `amqp`, `telegram`, `poll_inbox`, …) — the protocol
  defines the card, not the transports. A sender walks the list top-down and uses the
  first transport it can speak; no shared transport ⇒ the contact is known but
  unreachable (surfaced to the human, not silently dropped).
- `seq` is a monotonic version. Any envelope may piggyback `card_seq`; if a peer sees a
  higher seq than it has stored, it requests/accepts the newer card
  (`CARD-UPDATE` message). That's the whole re-discovery story: endpoints can change —
  Alice moves from HTTP to a queue — and contacts converge on the next exchange.

### Discovery

- **Bootstrap is out-of-band in v1.** You add a contact by receiving their card through
  some human channel (paste the JSON/QR into Telegram, "add contact" command). No global
  directory is *required* — but cards may carry optional `resolve` hints (a well-known
  URL, a DID) so that a card can also be *found* rather than handed over. That hint is
  the hook the social-network evolution (below) hangs on.
- **Introductions ride the trust graph**: since cards are self-signed, Alice can forward
  Carol's card in an `INTRODUCE` message. That's how transitive querying gets a route to
  Carol without me ever configuring her — the card is verifiable even though the channel
  (Alice) is just a relay. Accepting an introduced card creates a contact; it grants
  *nothing* (grants and trust stay empty until the owner sets them).

### Contacts (implementation)

The owner-side address book, persisted in SQLite alongside tasks/schedules:
`contacts(principal_id, display_name, card_json, card_seq, added_at, notes)` with grants
and trust keyed by `principal_id`. The Manager gets `list_contacts` / `add_contact` /
`update_contact` tools, so "add Alice as a contact, she trusts age keys, here's her
card" is a Telegram message, not a config edit.

## Wire protocol

Async-first (humans are in the loop; peers sleep). Signed JSON envelopes, **independent
of transport** — the same envelope is valid as an HTTPS POST body, an AMQP message, or a
file in a polled inbox:

```
QUERY       {id, from, to, scope, question, ttl_hops, provenance: [], proof: [], card_seq, sig}
ANSWER      {id, in_reply_to, from, answer, confidence, provenance, sig}
DECLINE     {id, in_reply_to, reason: :no_answer | :timeout | :unreachable}
ESCALATED   {id, in_reply_to, from, sig}    # reply-only: "a human was asked; answer may follow"
LIST-SCOPES {id, from, to, sig}             # "which of your scopes may I see?"
SCOPES      {id, in_reply_to, from, scopes: [{name, description?}], sig}
SUBSCRIBE   {id, from, to, scope, proof: [], sig}    # standing feed request; needs (scope, subscribe)
UNSUBSCRIBE {id, from, to, scope, sig}
PUBLISH     {id, from, scope, item, provenance, sig} # honored only against a live subscription
SAY         {id, thread, from, scope?, message, proof: [], card_seq, sig}  # first SAY opens a discussion; scope required there
CLOSE       {id, thread, from, reason?, sig}         # either side ends a discussion
INTRODUCE   {id, from, card: <signed contact card of a third party>, context}
CARD-UPDATE {id, from, card}                # my endpoints/providers changed
GOSSIP      {id, from, scope, item, why_you, provenance, sig}   # reserved — see Gossip
ESCALATE    {id, in_reply_to, question}     # internal: agent → its own human
```

- **Transport is an adapter, not part of the protocol.** In the Elixir app:
  `KbaseBot.Federation.Transport` behaviour with `deliver(envelope, endpoint)` plus
  inbound adapters (an HTTP endpoint, an AMQP consumer, …) that all normalize into one
  federation ingress. The protocol layer above never knows which pipe a message rode.
  KbaseBot v1 implements `https` inbound+outbound; outbound-only adapters for whatever
  friends run can be added without touching protocol code.
- Every inbound message resolves to a principal via the identity module *before* any
  LLM processing — envelope signature checked against the stored contact card.
  Unverifiable ⇒ dropped, exactly like today's unauthorized Telegram messages.
- Replies are envelopes too: an `ANSWER` arriving hours later via a different transport
  than the `QUERY` went out on is fine — correlation is by `id`, not by connection.
- `DECLINE`'s `:no_answer` is deliberately indistinguishable: "content exists but you
  hold no grant" and "no such content" are the same wire answer. Deny-by-default applies
  to the metadata channel too — a reason enum separating them would leak which scopes
  exist to principals who weren't granted even that.

### Human escalation

- **Inbound**: Alice's agent asks something my agent can't or shouldn't answer
  autonomously (no grant covers it, or confidence is low). The moment my agent surfaces
  it in my Telegram — "Alice's agent asks: … [answer / decline / grant movies to
  Alice]" — it replies `ESCALATED`, so the asking agent knows to wait instead of timing
  out; my eventual reply flows back as a signed `ANSWER` (or `DECLINE`) on the same
  exchange id. An inline "grant" action makes the privacy table grow organically
  instead of demanding upfront configuration.
- **Outbound**: symmetric; my agent's `QUERY` may come back with an `ESCALATED`
  envelope — sent only ever as a reply, by the target agent, when it hands the question
  to its human — and a human-authored answer hours later. Hence async ids, not
  request/response.

## Capability ceiling for outsiders

Hard rule: **capability follows the principal who initiated the exchange, not the
sender of the latest message.** Every envelope correlates (by `id`) to an exchange, and
the exchange's initiator determines what its handling may do:

- **Peer-initiated** (Kelvin's agent sends a `QUERY`): handling can produce exactly
  three effects — a bounded, policy-scoped **answering task** (read-only over granted
  scopes), a **question surfaced to the owner** (`ESCALATE` → Telegram), or a
  **`DECLINE`**. No schedule, no recurring task, no journal write, no KB mutation, no
  tool-request log, no new contact, no grant change — ever, regardless of what the
  message says.
- **Owner-initiated** (I asked my Manager to find movies; it queried Kelvin's agent):
  the returning `ANSWER` is data flowing into *my* standing request, handled by *my*
  task running with *my* capabilities. Writing what it learned to the KB is fine — the
  write authority is mine, granted when I asked. Kelvin sending an `ANSWER` I never
  asked for correlates to nothing and is dropped.

Subscriptions (`PUBLISH` feeds) fit the same rule: a subscription is standing owner
intent, so incoming published items may be ingested — because I initiated the
subscription, not because the peer pushed. Peer-initiated discussions fit it too: each
`SAY` resumes the same bounded answering task under a turn budget; turns never
accumulate capability. Gossip (below) is the same move as subscriptions with the
peer's judgment as the trigger — pre-authorized by a standing gossip grant, and
confined to a quarantined inbox.

### Foreign content in the KB

Peer-derived content that gets written is **quoted, attributed data — never owner
voice**. Frontmatter carries its origin:

```yaml
---
name: Movie recs via Kelvin, 2026-07
source: {principal: "sha256:kelvin…", exchange: "q_8f3a", received: 2026-07-02}
scopes: [movies]
---
```

Two reasons, both load-bearing: (a) trust weighting stays possible forever — if I later
downgrade Kelvin on movies, attributed entries can be re-weighed or purged; (b)
injection hygiene — when this file is retrieved into a future context, it reads as
"Kelvin claimed X", not as an owner-authored fact or instruction. Unattributed
federated writes are how one poisoned answer becomes permanent ground truth.

This is enforced by **routing, not prompting**:

- Inbound federation messages never enter the Manager loop. The Manager — with
  `spawn_task`, schedule CRUD, `journal_entry`, contact management — is reachable only
  from the owner's authenticated Telegram ingress.
- A verified peer `QUERY` spawns a **federation responder**: a task-layer loop whose
  toolset is fixed at construction to policy-filtered `search_knowledge` / `read_file` /
  `list_files` plus `answer_peer`, `decline`, and `escalate_to_owner`. The spawning code
  selects this toolset by principal; the LLM inside never has schedule/spawn/write tools
  to misuse, so no injection can conjure them.
- The responder is bounded like any task (turn cap, timeout) and cannot spawn further
  tasks — fan-out from a peer message is capped at one.
- Defense in depth: privileged tools (`spawn_task`, schedule CRUD, journal, contacts)
  also assert `principal == owner` inside `execute/2`, so even a future routing bug
  fails closed.
- Even the *escalate* path is rate-limited per principal: an outsider can queue a
  question to me, not flood my Telegram.

Corollary for transitive querying: a forwarded question arriving via Alice runs under
the *forwarder chain's* weakest grants and the same ceiling — hops never accumulate
capability.

## Gossip (deferred — sketch)

Status: **design later, after the trust algorithm is ironed out.** Sketched now only so
the protocol reserves room for it.

The scenario: Kelvin's interests align closely with mine — he's an authority on what's
interesting about computation. I don't want to only *pull* from him; I want his agent,
when it encounters something *it judges I'd care about*, to push it to mine. My agent
evaluates it and files it for me to browse later. Serendipity as a protocol feature.

How it stays inside the capability model:

- **A gossip grant is standing owner intent**: `gossip_from: {kelvin: [computation,
  movies]}` means "I delegate to Kelvin's agent the judgment of what's worth my
  attention on these topics." The push is peer-triggered, but the *authorization* is
  mine and revocable — same shape as a subscription, except the trigger is the peer
  agent's per-item judgment instead of a feed.
- **New envelope kind**: `GOSSIP {id, from, scope, item, why_you: "...", provenance,
  sig}`. `why_you` is the peer agent's one-line reason it thought of me — useful signal
  for my evaluator and for me. Gossip with no matching grant ⇒ `DECLINE` (and repeated
  offenders get rate-limited like any principal).
- **Quarantine-only writes.** The gossip evaluator is a constrained task (same ceiling
  as the federation responder) whose single write capability is *append to the gossip
  inbox* — `gossip/<scope>/…`, attributed frontmatter as in "Foreign content in the
  KB". It can never touch the main KB, no matter how good the item looks. Promotion
  out of the inbox is an owner action (or an owner-initiated task), by definition.
- **Structured per subject**: the inbox is organized by scope, so "show me the
  computation gossip" is a browse, and the daily briefing can say "3 items in gossip:
  computation" instead of interrupting per item.
- **The evaluator is where trust bites**: it scores each item against
  `trust(kelvin, computation)` and my current interests, deciding file / summarize /
  drop. This is why the feature waits for the trust algorithm.

The feedback loop is the payoff: my accept/promote/discard actions on gossip are
labeled per `(principal, scope)` — exactly the training signal the trust algorithm
needs to auto-tune weights ("Kelvin's computation gossip: 80% promoted; his movie
gossip: mostly discarded"). Gossip and trust co-evolve; that's the emergence.

## North star: an open social network

The address book is the seed, not the ceiling. The dream: this grows into an open
social network of personal agents — where "joining" means publishing a resolvable
contact card, and the network *is* the trust graph, not a platform.

The primitives are already the right ones, because they're the same ones the open
social protocols (Nostr, Scuttlebutt, ATProto) converged on:

- **Identity is a keypair, not an account on a server.** Nothing to migrate away from,
  no platform that can deplatform.
- **Cards are self-signed and channel-independent** — a card at a well-known URL or in a
  registry is a *profile*; the registry is untrusted infrastructure, not an authority.
- **Contacts + INTRODUCE + transitive trust already form a social graph.** Edges grow by
  introduction along existing trust, exactly how real social graphs grow.

What the network adds over the address book, in rough order:

1. **Public scopes.** A reserved `anyone` pseudo-principal that grants can name:
   `anyone: {movies: [query]}` makes my movie taste queryable by any verified principal.
   Deny-by-default is unchanged — public is one explicit grant, not a mode switch.
2. **Resolvable cards.** The `resolve` hint graduates into discovery: directories,
   DID resolution, webfinger-style lookup. Multiple registries can coexist because
   they only relay signed cards; they can't forge them.
3. **Public feeds.** `SUBSCRIBE`/`PUBLISH` are core now; what the network adds is
   `subscribe` granted to `anyone` — public scopes as open feeds. "Alice published to
   `movies`" is a briefing item, not a notification firehose.
4. **Reputation from provenance.** Signed provenance chains accumulate into exactly the
   data needed for web-of-trust-style discovery ("people my movie-trusted friends
   trust on movies") without any central ranking.

Design rule this imposes *now*: nothing in the protocol may assume the peer set is
small, mutually-known, or static. Concretely: grants must support pseudo-principals
(`anyone`), envelope kinds must be an open enum (unknown kinds ⇒ `DECLINE`, not crash),
and rate-limiting/blocklists are per-principal from day one — a public agent will
receive spam.

## Preparation in the current codebase

None of this requires building federation now. It requires not baking single-ownership
in any deeper, and un-baking it where it's cheap. Confirmed seams:

1. **Thread a principal through tool context.** Promote the untyped context map to a
   struct with a `principal` field; populate it in `Manager.execute_manager_tools/2`
   (`manager.ex:223`) and `Runner.execute_tools/2` (`runner.ex:51`). Today it's always
   the owner principal — the point is that tools stop assuming it.
2. **Stop leaking identity out of context.** `notify_user` reads the global
   `telegram_chat_id` from app env (`tools/notify_user.ex:28`) because the task context
   doesn't carry a chat id — fix by putting the destination in the Runner's context.
   Similarly `telegram/bot.ex:63` drops the sender id before `Ingress.push/1`; forward
   `{principal, text}` instead.
3. **Introduce `KbaseBot.Policy`** with `can?/3` returning `true` for the owner, and call
   it from `read_file` / `list_files` / `search_knowledge`. The call sites are the
   deliverable; the policy engine can stay trivial.
4. **Adopt the frontmatter convention now** (`scopes:` on new files, `.kbase-policy.yml`
   with a catch-all `private` default) so content written between now and federation is
   already labeled.
5. **Wrap the auth gate as an identity provider.** `authorized?/1` (`bot.ex:69`) becomes
   the `:telegram_owner` provider returning the owner principal — same behaviour, right
   shape.
6. **Keep `repo_path` access behind the tools.** It already is
   (`context/server.ex:18-33`); the rule is just: never add a code path that reads the KB
   without going through a Policy-checked tool.
7. **Mark privileged tools owner-only.** Once the principal rides in context (item 1),
   add an owner assertion at the top of `execute/2` in `spawn_task`, the schedule CRUD
   tools, and `journal_entry`. It's a no-op today (everything is the owner) but it means
   the capability ceiling exists in code before any federation ingress does.

## Prior art worth stealing from

- **Google A2A (agent2agent)** — agent discovery cards + task lifecycle over HTTP; the
  envelope/lifecycle shapes map well onto QUERY/ANSWER/ESCALATE. Its public AgentCard
  vs. authenticated extended-card split is the direct model for scope advertisement
  (public scopes on the card, per-principal `SCOPES` on request).
- **SPKI/SDSI** (Rivest & Lampson) — signed *authorization* certificates chained
  instead of identity certs: readable statements, attenuation-only delegation, chain
  verification. The delegation-record design is this, in JSON. Still the cleanest
  thinking in the space.
- **ZCAP-LD** — W3C's JSON capability chains: right shape (inspectable delegation
  documents), wrong baggage (JSON-LD). Steal the idea, not the format.
- **UCAN / Biscuit / macaroons** — the same idea serialized as JWTs (UCAN) or
  caveated blobs with a Datalog dialect (Biscuit). See-also only: opaque encodings
  defeat inspectability, and their offline-authority premise is deliberately rejected
  here — the live grant graph stays the source of truth.
- **PGP web of trust** — trust signatures with bounded depth are exactly the
  `transitive + max_hops` model, with 30 years of lessons about why defaults must be
  conservative.
- **DIDs / verifiable credentials** — a standards-track identity provider for when a
  friend-of-friend and I share no direct channel.
- **Nostr** — signed events + untrusted relays is the same shape as signed envelopes +
  pluggable transports; proof the model scales to an open network.
- **Secure Scuttlebutt** — friend-of-friend gossip replication is the closest existing
  thing to transitive scoped sharing; its lesson: social graphs grow by introduction.
- **AT Protocol (Bluesky)** — portable identity separated from hosting; what
  "resolvable cards" look like at consumer scale.
- **MCP** — not the protocol itself, but its lesson: capability discovery (contact
  cards) beats hardcoding what a peer can do.
- **XMPP/Matrix federation** — the cautionary tale: baking one transport into the
  protocol couples every peer to it forever. Signed envelopes over pluggable pipes
  avoid that.

## Threat model notes

- A peer agent's output is **untrusted input**: it can attempt prompt injection. Peer
  text must never reach the Manager with owner-level tool access; federated answers are
  data, quoted and attributed, not instructions.
- Grants are enforced in code (tool layer), never in prompts.
- Trust weights and the grant table are themselves private — never serialized to peers.
- Provenance chains are signed per hop, or transitivity becomes an anonymization layer
  for made-up answers.
- Revocation is grant-graph reachability, checked at presentation time: a proof (or a
  forwarded query) is honored only while a live path of sufficient-`depth` records
  covers its chain, so revoking a peer severs everyone downstream of them. Downstream
  revocation is expiry-bounded — delegated records are short-lived and re-issued; a
  per-principal blocklist stays as defense in depth.
