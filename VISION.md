# ZoneCapture — Vision: from links to trajectories

Owner statement, 2026-09-03. This is the design north star for features 2–4
and for anything that processes captured data.

## The core idea: information is stale relative to knowledge

What a person finds interesting today is only interesting *tomorrow* in
relation to the knowledge of tomorrow. A link about ABC captured today is
stale tomorrow — because tomorrow you can read, and read books. The link was
never the value.

**The durable part worth keeping is the topic and the trajectory.**

Example: 17 May 2024 — captured links about how to install Linux. As things
progress, the Linux-related searches drift toward kernels. The individual
links decay; the trajectory ("installing → internals → kernels") is the
signal.

## Projection

There is a projection side to this feature, similar to how an LLM predicts
the next token — but the thing being predicted is **the user's interest**:
given the trajectory so far, where does the interest go next? More
importantly, the system ends up being less about storing links and more
about being a **pre-amble to the input an LLM needs to improve on** —
sometimes even replacing pure Google searches and browsing by producing good
quality information about the topics of interest, and making good
conversation about them.

## What this means architecturally

The snapshots — what this app captures — are raw material. They require an
**inference stage** that acts on and processes the data:

1. **Capture (this app, done).** ⌘⇧L → url + title + note + timestamp +
   source app into `zonecapture.db`. Low friction is the whole point.
2. **Topicalize (inference stage, next).** Assign/derive `topic` per capture
   (the `links.topic` column is already reserved). Topics are discovered,
   not hand-labeled.
3. **Trajectories over time.** Sequences of topics + their drift are the
   stored memory — not the links themselves.
4. **Projection.** Predict the next likely interest; surface it.
5. **Feed the LLM.** Captured trajectories become preamble/context for
   models — possibly including **fine-tuning a tiny model** on them.

> "I believe in patterns as a memory instead of data as in text as memory."

## Corollaries

- Links are cheap and perishable; never build features whose value depends
  on a link staying alive.
- Time-stamped topic sequences are the first-class data structure.
- Anything that "parses" a capture (feature 2 page-content, feature 3
  screenshots) exists to feed the inference stage, not to archive HTML.
- The capture surface must stay instant and silent; all intelligence lives
  behind it, off the user's flow.

## Current groundwork (as of v0.1.2)

- `links.topic TEXT` column reserved in the schema (NULL until the
  inference stage fills it).
- `tools/zonectl` — read-side companion (list / search / export) for the
  capture database; the first surface the inference stage will plug into.
- Roadmap features 2–4 in `README.md` remain the build order.
