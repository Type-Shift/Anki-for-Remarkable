"""Turn a Quizlet set into a flashcard TSV for the reMarkable.

    fetch     Quizlet set URL -> deck TSV   (see NETWORK below)
    paste     Quizlet's own Export text -> deck TSV
    selftest  prove the parsing and filename rules still hold

Deck file format (fixed contract with the on-device reader):
    /home/root/flashcards/<deck name>.tsv
    UTF-8, one card per line, term<TAB>definition
    blank lines and #-comments ignored
    a literal two-character \\n inside a field means a line break

NETWORK: `fetch` is unverified. Quizlet serves a PerimeterX captcha page
(HTTP 403) to plain HTTP clients, so no live fetch has ever succeeded from
here -- or from an off-network fetcher tried as a control, so this is
Quizlet's own bot wall, not the school proxy. The code is kept because the
wall may lift, but `paste` is the path that actually works today. Defeating
the captcha is deliberately not attempted: the site's robots.txt also
disallows /webapi/ and /*/export$, leaving the set page the only route it
permits, and that one is gated.

    python quizlet2rm.py paste --title "French Food" --in export.txt --out-dir .
    python quizlet2rm.py fetch --url https://quizlet.com/123/x-flash-cards/
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.request

# A plain, generic browser UA. Never put anything identifying in here.
_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

_STYLE_RE = re.compile(r"<(style|script)\b.*?</\1>", re.S | re.I)
_BR_RE = re.compile(r"<br\s*/?>", re.I)
_P_RE = re.compile(r"</p\s*>", re.I)
_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"[ \t\x0b\f\r ]+")

# ponytail: rmanki.py has a strip_html too, but importing it drags in
# `anki.collection` at module scope, so this script would then only run under
# Anki's venv. Twelve duplicated lines beat that dependency.


def clean_field(raw: str) -> str:
    """Flatten one Quizlet term or definition to a single TSV field.

    Strips the HTML Quizlet embeds, then enforces the two format rules that
    matter: no literal tabs (that is the delimiter) and real newlines become
    the two characters backslash-n.
    """
    text = _STYLE_RE.sub("", raw)
    text = _BR_RE.sub("\n", text)
    text = _P_RE.sub("\n", text)
    text = _TAG_RE.sub("", text)
    text = html.unescape(text)
    # Unescape can reveal markup or a tab, so normalise whitespace after it.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [_WS_RE.sub(" ", ln).strip() for ln in text.split("\n")]
    lines = [ln for ln in lines if ln]
    return "\\n".join(lines)


# Spaces are excluded on purpose: the name goes into an scp argument and a
# BusyBox shell command unquoted, so underscores keep both trivially safe.
_NAME_OK_RE = re.compile(r"[^A-Za-z0-9._-]+")
_NAME_MAX = 60


def safe_deck_name(title: str) -> str:
    """Make an untrusted set title safe as a filename and an scp path part.

    This is a trust boundary: `title` is scraped from a web page and ends up
    in a local path and in `root@device:/home/root/flashcards/<name>.tsv`.
    Whitelist only, never a blacklist.
    """
    # Strip accents to ASCII so the device's font and scp both cope.
    folded = unicodedata.normalize("NFKD", title)
    ascii_only = folded.encode("ascii", "ignore").decode("ascii")
    name = _NAME_OK_RE.sub("_", ascii_only)
    name = re.sub(r"_+", "_", name)
    # A leading dash would be read as an option by scp/ssh; a leading dot
    # hides the file. Strip both ends of anything that is not alphanumeric.
    name = name.strip("._-")
    name = name[:_NAME_MAX].strip("._-")
    if not name:
        raise ValueError(
            "set title has no usable ASCII characters; pass --title yourself")
    # Belt and braces: the whitelist already excludes these, so a hit here
    # means the rules above were edited wrongly.
    assert not set(name) & set(" /\\:\t\n\"'`$;|&*?<>"), name
    assert name not in (".", "..") and not name.startswith("-"), name
    return name


# --- parsing ----------------------------------------------------------------

_TERM_KEYS = ("word", "term", "cardSide1", "front")
_DEF_KEYS = ("definition", "def", "cardSide2", "back")


def _walk_for_cards(node, out: list) -> None:
    """Collect {term, definition} pairs from anywhere in a decoded JSON blob.

    The exact key path inside Quizlet's page JSON could not be verified (the
    page is captcha-gated), so this looks for the shape rather than the path.
    ponytail: a generic walk also survives Quizlet reshuffling its payload;
    if it ever picks up junk pairs, pin it to the real path instead.
    """
    if isinstance(node, dict):
        term = next((node[k] for k in _TERM_KEYS
                     if isinstance(node.get(k), str)), None)
        definition = next((node[k] for k in _DEF_KEYS
                           if isinstance(node.get(k), str)), None)
        if term is not None and definition is not None:
            out.append((term, definition))
        for value in node.values():
            _walk_for_cards(value, out)
    elif isinstance(node, list):
        for value in node:
            _walk_for_cards(value, out)


def _json_after(text: str, start: int) -> str | None:
    """Slice the one balanced {...} that begins at or after `start`."""
    open_at = text.find("{", start)
    if open_at < 0:
        return None
    depth, in_str, esc = 0, False, False
    for i in range(open_at, len(text)):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return None


_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.S | re.I)
_BLOB_RE = re.compile(
    r"window\.Quizlet\[[^\]]+\]\s*=|__NEXT_DATA__[^>]*>", re.I)


def parse_page(page: str) -> tuple[str, list[tuple[str, str]]]:
    """Pull (title, cards) out of a Quizlet set page's embedded JSON."""
    cards: list[tuple[str, str]] = []
    for m in _BLOB_RE.finditer(page):
        blob = _json_after(page, m.end())
        if not blob:
            continue
        try:
            data = json.loads(blob)
        except ValueError:
            continue
        _walk_for_cards(data, cards)
        if cards:
            break

    title = ""
    tm = _TITLE_RE.search(page)
    if tm:
        title = clean_field(tm.group(1))
        # "Foo Flashcards | Quizlet" -> "Foo"
        title = re.split(r"\s*\|\s*", title)[0]
        title = re.sub(r"\s*flashcards?\s*$", "", title, flags=re.I).strip()
    return title, cards


def parse_export(text: str, between: str = "\t", rows: str = "\n") -> list:
    """Parse Quizlet's own Export output.

    Quizlet's export screen lets you choose the separators; the defaults here
    match its "Tab" / "New line" preset, which is already this format.
    """
    cards = []
    chunks = text.split(rows) if rows != "\n" else text.splitlines()
    for chunk in chunks:
        if not chunk.strip():
            continue
        if between not in chunk:
            continue                      # heading or stray line, not a card
        term, definition = chunk.split(between, 1)
        cards.append((term, definition))
    return cards


def to_tsv(cards: list[tuple[str, str]]) -> str:
    """Render cards as the deck file body, dropping any that empty out."""
    lines = []
    for raw_term, raw_def in cards:
        term, definition = clean_field(raw_term), clean_field(raw_def)
        if term and definition:
            lines.append(f"{term}\t{definition}")
    return "\n".join(lines) + "\n"


def fetch_page(url: str) -> str:
    """GET a Quizlet set page. Raises with advice when the captcha wall hits."""
    if not re.match(r"https://(www\.)?quizlet\.com/", url):
        raise ValueError(f"not a quizlet.com https URL: {url}")
    req = urllib.request.Request(url, headers={
        "User-Agent": _UA,
        "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-GB,en;q=0.9",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        if e.code in (403, 401):
            raise SystemExit(
                f"Quizlet returned HTTP {e.code} (bot wall / login gate).\n"
                "Use the export fallback instead:\n"
                "  1. open the set, Export, separator Tab / New line\n"
                "  2. copy the box, save it to a file\n"
                "  3. quizlet2rm.py paste --title \"<name>\" --in <file>")
        raise


def write_deck(name: str, cards: list, out_dir: str) -> str:
    """Write <out_dir>/<safe name>.tsv and return the path."""
    if not cards:
        raise SystemExit("no cards found -- nothing written")
    safe = safe_deck_name(name)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, safe + ".tsv")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(to_tsv(cards))
    print(f"{len(cards)} cards -> {path}")
    return path


# --- selftest ---------------------------------------------------------------

# A hand-built page in the documented shape. It is NOT a captured Quizlet
# response -- none could be obtained (see NETWORK above) -- so it proves the
# extractor's logic, not that it matches Quizlet's live payload.
_SAMPLE = '''<!DOCTYPE html><html><head>
<title>Le Petit Déjeuner | Quizlet</title></head><body>
<script>window.Quizlet["setPageData"] = {"set":{"title":"Le Petit D\\u00e9jeuner"},
"termIdToTermsMap":{"1":{"id":1,"word":"le pain","definition":"bread"},
"2":{"id":2,"word":"l'<b>oeuf</b>","definition":"the egg<br>(boiled)"},
"3":{"id":3,"word":"the\\tjam","definition":"la confiture &amp; co"}}};</script>
</body></html>'''


def selftest() -> int:
    title, cards = parse_page(_SAMPLE)
    assert title == "Le Petit Dejeuner" or title == "Le Petit Déjeuner", title
    assert len(cards) == 3, cards
    assert ("le pain", "bread") in cards, cards

    body = to_tsv(cards)
    lines = body.splitlines()
    assert len(lines) == 3, lines
    # every line is exactly one tab: term<TAB>definition
    for ln in lines:
        assert ln.count("\t") == 1, ln
    # HTML stripped, <br> became the two literal characters backslash-n
    assert lines[1] == "l'oeuf\tthe egg\\n(boiled)", lines[1]
    assert "\\n" in lines[1] and "\n" not in lines[1]
    # a tab inside a field must not survive as a tab
    assert lines[2].split("\t")[0] == "the jam", lines[2]
    assert lines[2].split("\t")[1] == "la confiture & co", lines[2]
    assert body.endswith("\n")

    # export fallback parses to the same cards
    exported = "le pain\tbread\nl'oeuf\tthe egg\n\nthe jam\tla confiture\n"
    assert len(parse_export(exported)) == 3
    assert parse_export(exported)[0] == ("le pain", "bread")
    # a custom separator preset
    assert parse_export("a=1;b=2", between="=", rows=";") == [("a", "1"), ("b", "2")]

    # filename trust boundary
    assert safe_deck_name("Le Petit Déjeuner") == "Le_Petit_Dejeuner"
    assert safe_deck_name("../../etc/passwd") == "etc_passwd"
    assert safe_deck_name("-rf me") == "rf_me"
    assert safe_deck_name("a/b\\c:d") == "a_b_c_d"
    assert safe_deck_name('x"; rm -rf /; echo "y') == "x_rm_-rf_echo_y"
    assert safe_deck_name("  ...dots...  ") == "dots"
    # no name may ever carry a space or a shell/scp metacharacter
    for probe in ("a b", "x;y", "p|q", "$HOME", "`id`", "a\tb", "..", "/", "-x"):
        try:
            assert " " not in safe_deck_name(probe)
        except ValueError:
            pass
    assert len(safe_deck_name("W" * 300)) == _NAME_MAX
    for bad in ("", "   ", "...", "中文", "///"):
        try:
            safe_deck_name(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"should have been rejected: {bad!r}")

    print("selftest ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_fetch = sub.add_parser("fetch", help="Quizlet set URL -> deck TSV")
    p_fetch.add_argument("--url", required=True)
    p_fetch.add_argument("--title", default=None, help="override the set title")
    p_fetch.add_argument("--out-dir", default=".")

    p_paste = sub.add_parser("paste", help="Quizlet Export text -> deck TSV")
    p_paste.add_argument("--title", required=True)
    p_paste.add_argument("--in", dest="infile", default="-",
                         help="file of exported text, or - for stdin")
    p_paste.add_argument("--between", default="\t", help="term/definition separator")
    p_paste.add_argument("--rows", default="\n", help="card separator")
    p_paste.add_argument("--out-dir", default=".")

    sub.add_parser("selftest", help="prove the parsing rules still hold")

    args = ap.parse_args()
    if args.cmd == "selftest":
        return selftest()

    if args.cmd == "fetch":
        page = fetch_page(args.url)
        title, cards = parse_page(page)
        if not cards:
            raise SystemExit(
                "fetched the page but found no cards in it -- it was probably a "
                "captcha or login page. Use `paste` (see --help).")
        write_deck(args.title or title or "Quizlet Set", cards, args.out_dir)
        return 0

    text = (sys.stdin.read() if args.infile == "-"
            else open(args.infile, encoding="utf-8-sig").read())
    cards = parse_export(text, args.between, args.rows)
    write_deck(args.title, cards, args.out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
