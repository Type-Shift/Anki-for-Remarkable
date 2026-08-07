"""PC-side half of offline Anki for the reMarkable 1.

The tablet is a dumb review terminal: it holds a prefetched batch of cards,
records which button you pressed, and hands the queue back when it
reconnects. All scheduling happens here, using Anki's real library, so the
tablet can never corrupt the collection.

    export   pull due cards into a batch file for the tablet
    apply    apply the tablet's answer queue to the collection
    selftest prove the round-trip against a throwaway collection

Run with Anki's bundled Python:
    %LOCALAPPDATA%\\AnkiProgramFiles\\.venv\\Scripts\\python.exe rmanki.py ...

Anki must be CLOSED when using a real collection -- it holds a lock.
"""

from __future__ import annotations

import argparse
import base64
import html
import json
import os
import re
import sys
import tempfile
import time

from anki.collection import Collection
from anki.scheduler.v3 import SchedulingStates

BATCH_VERSION = 1

# --- text rendering ---------------------------------------------------------
# The tablet has no HTML or image support, so cards are flattened to plain
# text here rather than on-device.

_STYLE_RE = re.compile(r"<(style|script)\b.*?</\1>", re.S | re.I)
_BR_RE = re.compile(r"<br\s*/?>", re.I)
_HR_RE = re.compile(r"<hr[^>]*>", re.I)
_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"[ \t]+")
_NL_RE = re.compile(r"\n{3,}")

# Anki wraps numbers in Unicode bidi isolates (FSI/PDI). The reMarkable's
# e-paper font has no glyphs for these, so they show as boxes.
_BIDI_RE = re.compile(r"[⁦-⁩‎‏]")


def clean_label(text: str) -> str:
    """Strip bidi control characters that render as boxes on e-paper."""
    return _BIDI_RE.sub("", text).strip()


def strip_html(raw: str) -> str:
    """Flatten Anki's rendered HTML to plain text."""
    text = _STYLE_RE.sub("", raw)
    text = _BR_RE.sub("\n", text)
    text = _HR_RE.sub("\n---\n", text)
    text = _TAG_RE.sub("", text)
    text = html.unescape(text)
    text = _WS_RE.sub(" ", text)
    text = _NL_RE.sub("\n\n", text)
    return text.strip()


def split_answer(question: str, answer: str) -> str:
    """Anki's answer field repeats the question; keep only the back."""
    if "---" in answer:
        tail = answer.split("---", 1)[1].strip()
        if tail:
            return tail
    if answer.startswith(question):
        return answer[len(question):].lstrip("-\n ").strip()
    return answer


# --- export -----------------------------------------------------------------

def export_batch(col_path: str, deck: str | None, limit: int, out_path: str) -> dict:
    """Read due cards into a portable batch file. Does not modify scheduling."""
    col = Collection(col_path)
    try:
        if deck:
            deck_id = col.decks.id_for_name(deck)
            if deck_id is None:
                raise SystemExit(f"No such deck: {deck!r}")
            col.decks.select(deck_id)

        queued = col.sched.get_queued_cards(fetch_limit=limit)

        cards = []
        for qc in queued.cards:
            card = col.get_card(qc.card.id)
            q_text = strip_html(card.question())
            a_text = split_answer(q_text, strip_html(card.answer()))
            labels = [clean_label(l) for l in col.sched.describe_next_states(qc.states)]

            cards.append({
                "card_id": qc.card.id,
                "question": q_text,
                "answer": a_text,
                "buttons": labels,
                # The scheduling states are opaque to the tablet; it hands
                # them straight back so we can schedule accurately at apply
                # time. Same passthrough model AnkiWeb's own reviewer uses.
                "states_b64": base64.b64encode(qc.states.SerializeToString()).decode("ascii"),
            })

        counts = col.sched.counts()
        batch = {
            "version": BATCH_VERSION,
            "exported_at": int(time.time()),
            "deck": deck or "(whole collection)",
            "counts": {"new": counts[0], "learning": counts[1], "review": counts[2]},
            "cards": cards,
        }
    finally:
        col.close()

    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(batch, fh, ensure_ascii=False, indent=1)

    return batch


# --- apply ------------------------------------------------------------------

def apply_queue(col_path: str, queue_path: str) -> dict:
    """Apply the tablet's recorded answers to the collection."""
    with open(queue_path, encoding="utf-8") as fh:
        queue = json.load(fh)

    answers = queue["answers"] if isinstance(queue, dict) else queue

    col = Collection(col_path)
    applied, skipped = 0, []
    try:
        for entry in answers:
            cid = int(entry["card_id"])
            rating = int(entry["rating"])
            if rating not in (1, 2, 3, 4):
                skipped.append((cid, f"bad rating {rating}"))
                continue

            try:
                card = col.get_card(cid)
            except Exception as exc:
                skipped.append((cid, f"card missing: {exc}"))
                continue

            states = SchedulingStates()
            states.ParseFromString(base64.b64decode(entry["states_b64"]))

            # answer_card derives time-taken from the review timer, so it
            # must be started even though the real thinking happened offline.
            card.start_timer()
            answer = col.sched.build_answer(card=card, states=states, rating=rating)

            # Preserve how long the card actually took on the tablet, if sent.
            if entry.get("time_taken_ms"):
                answer.milliseconds_taken = int(entry["time_taken_ms"])

            col.sched.answer_card(answer)
            applied += 1
    finally:
        col.close()

    return {"applied": applied, "skipped": skipped}


# --- selftest ---------------------------------------------------------------

def selftest() -> int:
    """Full round-trip on a throwaway collection. Touches nothing real."""
    tmp = tempfile.mkdtemp(prefix="rmanki_selftest_")
    col_path = os.path.join(tmp, "test.anki2")
    batch_path = os.path.join(tmp, "batch.json")
    queue_path = os.path.join(tmp, "queue.json")

    print(f"throwaway collection: {col_path}")

    col = Collection(col_path)
    model = col.models.by_name("Basic")
    deck_id = col.decks.id("Selftest")
    for i in range(8):
        note = col.new_note(model)
        note["Front"] = f"What is {i} + {i}?"
        note["Back"] = f"{i + i}"
        col.add_note(note, deck_id)
    col.decks.select(deck_id)
    before_counts = col.sched.counts()
    col.close()
    print(f"seeded 8 cards; counts before = {before_counts}")

    batch = export_batch(col_path, "Selftest", limit=5, out_path=batch_path)
    print(f"exported {len(batch['cards'])} cards -> {batch_path}")
    if not batch["cards"]:
        print("FAIL: export produced no cards")
        return 1

    sample = batch["cards"][0]
    print(f"  sample Q: {sample['question']!r}")
    print(f"  sample A: {sample['answer']!r}")
    print(f"  buttons : {sample['buttons']}")
    if "<" in sample["question"] or "style" in sample["question"]:
        print("FAIL: HTML leaked into question text")
        return 1

    # Simulate offline reviewing: answer everything "Good".
    answers = [
        {"card_id": c["card_id"], "rating": 3,
         "answered_at": int(time.time()), "time_taken_ms": 4200,
         "states_b64": c["states_b64"]}
        for c in batch["cards"]
    ]
    with open(queue_path, "w", encoding="utf-8") as fh:
        json.dump({"version": BATCH_VERSION, "answers": answers}, fh, indent=1)
    print(f"simulated {len(answers)} offline answers -> {queue_path}")

    result = apply_queue(col_path, queue_path)
    print(f"applied={result['applied']} skipped={result['skipped']}")
    if result["applied"] != len(answers):
        print("FAIL: not all answers applied")
        return 1

    col = Collection(col_path)
    revlog = col.db.scalar("select count() from revlog")
    reps = col.db.scalar("select count() from cards where reps > 0")
    after_counts = col.sched.counts()
    col.close()

    print(f"revlog rows = {revlog}, cards with reps>0 = {reps}")
    print(f"counts after = {after_counts}")

    if revlog != len(answers):
        print(f"FAIL: expected {len(answers)} revlog rows, got {revlog}")
        return 1
    if reps != len(answers):
        print(f"FAIL: expected {len(answers)} reviewed cards, got {reps}")
        return 1

    print("\nPASS: offline review round-trip works end to end")
    return 0


# --- cli --------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_exp = sub.add_parser("export", help="pull due cards into a batch file")
    p_exp.add_argument("--collection", required=True)
    p_exp.add_argument("--deck", default=None)
    p_exp.add_argument("--limit", type=int, default=100)
    p_exp.add_argument("--out", required=True)

    p_app = sub.add_parser("apply", help="apply the tablet's answer queue")
    p_app.add_argument("--collection", required=True)
    p_app.add_argument("--queue", required=True)

    sub.add_parser("selftest", help="round-trip test on a throwaway collection")

    args = ap.parse_args()

    if args.cmd == "selftest":
        return selftest()

    if args.cmd == "export":
        batch = export_batch(args.collection, args.deck, args.limit, args.out)
        print(f"exported {len(batch['cards'])} cards to {args.out}")
        print(f"counts: {batch['counts']}")
        return 0

    if args.cmd == "apply":
        result = apply_queue(args.collection, args.queue)
        print(f"applied {result['applied']} answers")
        for cid, why in result["skipped"]:
            print(f"  skipped {cid}: {why}", file=sys.stderr)
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
