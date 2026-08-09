# Roadmap — where this project is going

KbaseBot started as a Telegram assistant over an encrypted markdown knowledge
base. The longer arc, which current architecture decisions already serve, is
what Gwern's [Guardian Angel](https://gwern.net/guardian-angel) essay calls a
personal model: an assistant aligned to a single person, whose knowledge of
that person eventually lives in model weights rather than only in retrieved
files. This doc records the direction so that contributors (and future
maintainers) can tell which properties are load-bearing.

## The premise: the corpus is the asset

Base models improve and get replaced; fine-tuned adapters are cheap to
retrain. The one thing that cannot be regenerated is a longitudinal,
provenance-clean record of the owner: what they said, what they corrected,
what they decided, with authorship and time attached. So the capture layer is
built first and everything else derives from it.

**Already implemented** (see the code, not just this doc):

- Every server-side knowledge-base mutation flows through a write-through
  layer (`KbaseBot.KB.Writer`) into an append-only `kb_writes` log carrying
  `{ts, path, op, content, actor, source, meta}`. Files on disk are a
  materialized view, rebuilt from the log on boot — which also makes the
  server disposable.
- Conversation history, task outcomes, and inbox verdicts persist in SQLite,
  designed to be replicated off-host (Litestream) rather than backed up ad
  hoc.
- A `log_preference` tool captures corrections and preferences as structured
  records the moment they happen — the highest-value training signal there
  is.
- `mix kbase_bot.corpus.export` derives corpus JSONL (one record per event,
  with author/sensitivity/kind labels) from the database.

**Still to build in the capture layer**: one-time import of external writing
(essays, old chat exports), scheduled elicitation (the bot asks or predicts
something about the owner and records the outcome), and per-record
sensitivity tagging beyond a blanket default.

## The memory architecture: three layers, three timescales

The design follows a complementary-learning-systems split — the same shape as
episodic memory consolidating into cortex:

| Layer | Timescale | Role |
|---|---|---|
| Raw corpus (`kb_writes`, conversation, exports) | permanent, append-only | episodic ground truth; never curated at capture |
| Derived representation of the owner | rebuilt periodically | an editable document of beliefs/preferences with per-claim provenance and confidence, distilled from the corpus by a frontier model |
| Fine-tuned adapter (LoRA on a small open model) | retrained occasionally | slow, dispositional knowledge: voice, values, stable preferences |

The split is by **rate of change**. Weights are nearly impossible to revise,
so only slow-changing dispositional structure gets consolidated into them;
fast-changing facts stay in the editable layers. The representation is also
the **augmentation engine**: at training time it
generates the synthetic Q&A pairs and prediction traces the adapter trains
on, and its held-out claims double as the eval set ("does the model know the
owner" becomes a measurable question).

## The compute architecture: frontier rents reasoning, local owns identity

Two model tiers with a deliberate division of labor:

- **Frontier models over API** handle reasoning, agent work, and corpus
  derivation. They are also the data factory: their outputs (captured
  conversations, derived representations, synthetic training data) distill
  into the local model over time.
- **A small open model (~8–27B), fine-tuned, running on owned consumer
  GPUs** is the person-layer: always on, private, free per token. Training
  runs happen on rented datacenter GPUs (hours, not months); inference and
  evals run at home. Precedent that specialization beats scale for this
  layer: Plastic Labs' Neuromancer, an 8B fine-tune outperforming frontier
  models at social reasoning.

Privacy boundary, stated once: an adapter trained on sensitive data is a
lossy copy of that data. Adapters touching medical-tier content are trained
and run on owned hardware only.

## Federation: from protocol to network

Federation v1 (implemented — see
[`federation-guide.md`](federation-guide.md)) covers identity, cards, grants,
confined peer interactions, quarantine, and delivery. The deferred tail, in
rough order:

1. **First real peers.** The protocol was built for a second user who does
   not exist yet; everything below needs live traffic first.
2. **Trust weights.** Every inbox promote/discard verdict is already logged
   per peer and topic; once enough signal accumulates, quarantine strictness
   and gossip filtering become functions of it.
3. **Gossip.** Peer agents pushing items they judge you would care about,
   filtered by trust weights.
4. **Delegation chains.** The verifier already freezes the depth/attenuation
   arithmetic for multi-hop grants (Alice grants Bob, Bob re-grants Carol,
   attenuated); v1 accepts only direct grants.
5. **Discovery.** INTRODUCE / web-of-trust so peers can meet through mutual
   contacts instead of pasting cards.

## Non-goals

- Multi-user SaaS. One bot serves one owner; scale happens by federation of
  sovereign instances, not by tenancy.
- Migration machinery. The SQLite schema evolves by wipe-and-reboot; the
  knowledge base (and the corpus derived from everything) is the only state
  that persists across schema generations.
- Engagement. The bot exists to compress the owner's attention, not to
  consume it.
