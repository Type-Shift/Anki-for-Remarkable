# Offline Anki for reMarkable 1

Goal: review flashcards offline on the reMarkable 1, syncing when it
reconnects to WiFi.

## Why the current app can't do this

RmAnki is a thin client over AnkiWeb's private web-reviewer API
(`/svc/decks/*`, `/svc/study/study-cards`). No local collection. That API is
stateful and one-card-at-a-time — there is no bulk "give me today's due
cards" call, and you cannot advance the queue without answering. An offline
queue cannot be bolted on; the data isn't obtainable.

Worse, `answerCard` is optimistic: if the background POST fails it is only
written to `qDebug`. No retry, no queue, no on-screen error. Reviews are
silently lost — and this tablet drops WiFi aggressively.

## Architecture: PC is the brain, tablet is a terminal

The PC holds the collection and does all scheduling using Anki's real Python
library. The tablet holds a prefetched batch, records button presses, and
hands the queue back on reconnect.

    PC  --export batch.json-->  tablet   (question, answer, button labels,
                                          opaque scheduling states)
    tablet --queue.json-->  PC           (card_id, rating, time taken)
    PC applies via anki lib, then syncs onward normally

The tablet never needs a scheduler, never needs the sync protocol, and
cannot corrupt the collection. Scheduling states are passed through
opaquely — the same model AnkiWeb's own reviewer uses.

### Rejected: cross-compiling rslib

Was the plan until the school-PC constraint landed. It needs a Linux
cross-compilation environment; WSL requires admin rights not available here.
CI-only iteration also makes a large ARM Rust build painful to debug. And
477 MB RAM with no swap made the memory budget a real risk.

### Rejected: hand-writing Anki's sync protocol

`/sync/meta`, `applyChanges`, `chunk`, `sanityCheck2`, USN bookkeeping,
tombstones. Subtle bugs there don't fail loudly, they corrupt.

## Build constraint: no local Linux

School computer. No WSL (needs admin), no Docker, no Rust, no compilers.
The device has **no scripting runtime** (no python/lua/node/perl), so the
tablet app must be compiled.

**Solution: GitHub Actions.** RmAnki already builds in CI on `ubuntu-latest`,
fetching the reMarkable SDK from a public URL with no login. Verified the
rM1 toolchain is publicly fetchable:

    https://storage.googleapis.com/remarkable-codex-toolchain/codex-x86_64-cortexa9hf-neon-rm10x-toolchain-3.1.15.sh

(The workflow shipped in the repo targets Paper Pro / `ferrari` / cortexa53,
not rM1 — it needs swapping for the cortexa9hf toolchain above.)

## Measured device constraints (2026-08-07, over SSH)

| Property | Value |
|---|---|
| Arch | armv7l, 1 core |
| RAM | 477 MB total, ~388 MB available, **no swap** |
| glibc | 2.39 |
| Storage | 5.6 GB free on `/home` |
| Scripting runtimes | none |
| Qt5 | statically linked into existing binary |

## Verified API facts (Anki 25.09.4, tested locally)

- `col.sched.get_queued_cards(fetch_limit=N)` returns cards **with**
  `SchedulingStates` (`current/again/hard/good/easy`) — serialisable protobuf.
- `col.sched.build_answer(...)` + `answer_card(...)` applies a review.
- **`card.start_timer()` is required first** — otherwise `answer_card`
  raises `TypeError: unsupported operand type(s) for -: 'float' and 'NoneType'`.
- `col.sched.describe_next_states(states)` gives button labels, but wraps
  numbers in Unicode bidi isolates (U+2068/U+2069) which render as boxes on
  e-paper. Stripped in `clean_label()`.

## Device access

- IP `192.168.68.64`, root over SSH, key auth installed.
- Sleeps and drops WiFi ~2 min after screen-off.
- `xochitl` must be stopped for a Qt epaper app to own the framebuffer.
- Launch must use `setsid` — plain `nohup ... &` does not survive a scripted
  SSH disconnect (dropbear signals the process group).

## Status

- **PC half: built and tested.** `pc/rmanki.py` with `export` / `apply` /
  `selftest`. Selftest passes: 5 cards exported, answered offline, applied,
  5 revlog rows written, intervals scheduled correctly.
- **Tablet half: not started.** Blocked on a GitHub repo for CI builds.

Real collection at `%APPDATA%\Anki2\User 1\collection.anki2` (3.6 MB) has
not been touched. All testing uses throwaway collections in temp dirs.
