//! C shim over Anki's own Rust backend (rslib).
//!
//! Replaces the approximation the app shipped with. Previously the tablet
//! replayed interval labels computed on the PC at export time, which cannot
//! work out what an interval becomes after a learning step: a card taken
//! through several steps landed where its final grade put it, not where
//! Anki's own progression would.
//!
//! Linking rslib removes that entirely -- the same scheduler and the same
//! collection format as the desktop.
//!
//! Everything crosses the boundary as JSON. rslib's protobuf service
//! interface would drag a protobuf runtime into the Qt app for no gain: the
//! app already parses JSON, and these payloads are tiny.
//!
//! Errors are carried as plain Strings rather than rslib's AnkiError.
//! Constructing an AnkiError means going through its snafu context selectors,
//! which would pin us to the exact snafu version rslib vendors for no
//! benefit -- we only ever render the message.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::Mutex;

use anki::collection::{Collection, CollectionBuilder};
use anki::decks::DeckId;
// counts_for_deck_today is inherent-private; it reaches us through this trait.
use anki::services::SchedulerService;
use serde_json::{json, Value};

type ShimResult<T> = std::result::Result<T, String>;

/// Flatten anything displayable into our String error type.
fn flat<T, E: std::fmt::Display>(r: std::result::Result<T, E>) -> ShimResult<T> {
    r.map_err(|e| e.to_string())
}

// rslib's Collection is not Sync, and the Qt side is single-threaded anyway.
// A process-wide handle keeps the C surface simple: no pointer lifetimes to
// get wrong across the FFI boundary.
static COLLECTION: Mutex<Option<Collection>> = Mutex::new(None);

fn to_c_string(v: Value) -> *mut c_char {
    match CString::new(v.to_string()) {
        Ok(s) => s.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn err_json(context: &str, e: impl std::fmt::Display) -> *mut c_char {
    to_c_string(json!({ "ok": false, "error": format!("{context}: {e}") }))
}

fn c_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// Free any string this library returned.
#[no_mangle]
pub extern "C" fn ankicore_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

/// Version of the linked rslib, so the device can prove what it is running.
#[no_mangle]
pub extern "C" fn ankicore_version() -> *mut c_char {
    to_c_string(json!({ "ok": true, "version": anki::version::version() }))
}

/// Open (creating if absent) the collection at `path`.
#[no_mangle]
pub extern "C" fn ankicore_open(path: *const c_char) -> *mut c_char {
    let path = match c_str(path) {
        Some(p) => p.to_owned(),
        None => return err_json("open", "invalid path"),
    };

    match CollectionBuilder::new(path).build() {
        Ok(col) => {
            *COLLECTION.lock().unwrap() = Some(col);
            to_c_string(json!({ "ok": true }))
        }
        Err(e) => err_json("open", e),
    }
}

/// Close the collection, flushing to disk.
#[no_mangle]
pub extern "C" fn ankicore_close() -> *mut c_char {
    let mut guard = COLLECTION.lock().unwrap();
    match guard.take() {
        Some(col) => match col.close(None) {
            Ok(_) => to_c_string(json!({ "ok": true })),
            Err(e) => err_json("close", e),
        },
        None => to_c_string(json!({ "ok": true })),
    }
}

fn with_collection<F>(f: F) -> *mut c_char
where
    F: FnOnce(&mut Collection) -> ShimResult<Value>,
{
    let mut guard = COLLECTION.lock().unwrap();
    match guard.as_mut() {
        Some(col) => match f(col) {
            Ok(mut out) => {
                if let Some(obj) = out.as_object_mut() {
                    obj.insert("ok".into(), Value::Bool(true));
                }
                to_c_string(out)
            }
            Err(e) => err_json("collection", e),
        },
        None => err_json("collection", "not open"),
    }
}

/// Deck tree with the counts Anki itself would show, honouring daily limits.
#[no_mangle]
pub extern "C" fn ankicore_deck_list() -> *mut c_char {
    with_collection(|col| {
        let tree = flat(col.deck_tree(Some(anki::prelude::TimestampSecs::now())))?;

        // Flatten depth-first so QML keeps a simple list model, but carry the
        // level so it can indent exactly as the desktop does.
        fn walk(node: &anki_proto::decks::DeckTreeNode, depth: usize, out: &mut Vec<Value>) {
            // The synthetic root carries no deck of its own.
            if depth > 0 {
                out.push(json!({
                    "id": node.deck_id,
                    "name": node.name,
                    "level": depth - 1,
                    "collapsed": node.collapsed,
                    "has_children": !node.children.is_empty(),
                    "new": node.new_count,
                    "learn": node.learn_count,
                    "review": node.review_count,
                    "due": node.new_count + node.learn_count + node.review_count,
                }));
            }
            // Always recurse. Pruning collapsed branches here would make the
            // tree unexpandable on the device, since collapse state cannot be
            // written back yet. The caller hides children instead, seeded
            // from each node's own collapsed flag.
            for child in &node.children {
                walk(child, depth + 1, out);
            }
        }

        let mut decks = Vec::new();
        walk(&tree, 0, &mut decks);
        Ok(json!({ "decks": decks }))
    })
}

/// The next card the scheduler would show for `deck_id`, rendered to plain
/// text, with the four button labels Anki would print.
#[no_mangle]
pub extern "C" fn ankicore_next_card(deck_id: i64) -> *mut c_char {
    with_collection(move |col| {
        flat(col.set_current_deck(DeckId(deck_id)))?;

        let counts = flat(col.counts_for_deck_today(DeckId(deck_id).into()))?;

        let queued = match flat(col.get_next_card())? {
            Some(q) => q,
            None => {
                return Ok(json!({
                    "card": Value::Null,
                    "new": counts.new,
                    "review": counts.review,
                }))
            }
        };

        let card_id = queued.card.id();
        let rendered = flat(col.render_existing_card(card_id, false, false))?;

        // The device has no HTML or image support, so flatten here rather
        // than shipping markup the QML cannot draw.
        let question = strip_html(&rendered.question().to_string());
        let answer_full = strip_html(&rendered.answer().to_string());
        let answer = split_answer(&question, &answer_full);

        let labels = flat(col.describe_next_states(&queued.states))?;

        Ok(json!({
            "card": {
                "id": card_id.0,
                "question": question,
                "answer": answer,
                "buttons": labels,
            },
            "new": counts.new,
            "review": counts.review,
        }))
    })
}

/// Answer the current card. `rating` is 1..4 in the UI's scale (Again..Easy).
#[no_mangle]
pub extern "C" fn ankicore_answer_card(
    card_id: i64,
    rating: c_int,
    milliseconds_taken: c_int,
) -> *mut c_char {
    if !(1..=4).contains(&rating) {
        return err_json("answer_card", format!("rating must be 1-4, got {rating}"));
    }

    with_collection(move |col| {
        let queued =
            flat(col.get_next_card())?.ok_or_else(|| "no card to answer".to_string())?;

        if queued.card.id().0 != card_id {
            return Err("card on screen is no longer the scheduler's next card".into());
        }

        // The UI scale is 1-4 and matches the revlog `ease` column. Mapping it
        // onto the wrong state silently records every review one step easier,
        // and only Easy fails loudly -- that cost a real bug once already.
        let states = queued.states;
        let (new_state, rating_enum) = match rating {
            1 => (states.again, anki::scheduler::answering::Rating::Again),
            2 => (states.hard, anki::scheduler::answering::Rating::Hard),
            3 => (states.good, anki::scheduler::answering::Rating::Good),
            _ => (states.easy, anki::scheduler::answering::Rating::Easy),
        };

        let mut answer = anki::scheduler::answering::CardAnswer {
            card_id: queued.card.id(),
            current_state: states.current,
            new_state,
            rating: rating_enum,
            answered_at: anki::prelude::TimestampMillis::now(),
            milliseconds_taken: milliseconds_taken.max(0) as u32,
            custom_data: None,
            // The card came from the scheduler's queue, not a preview.
            from_queue: true,
        };

        flat(col.answer_card(&mut answer))?;
        Ok(json!({}))
    })
}

// Deck collapsing is handled by the QML side for now. rslib's public entry
// point for it could not be confirmed without guessing at a type path, and
// the deck tree already reports each deck's collapsed state, so nothing is
// lost by deferring the write-back.

// Native sync is deliberately absent for now. rslib's normal_sync and
// sync_login both take a reqwest::Client constructed rslib's own way, and
// guessing that constructor risks a version mismatch against the reqwest it
// vendors. Sync stays brokered by the PC, which is already proven, until the
// client builder can be confirmed against a green build.

// --- text rendering ---------------------------------------------------------

fn strip_html(raw: &str) -> String {
    // Mirrors what the PC-side exporter did, so cards read the same after the
    // switch to on-device rendering.
    let no_style = regex_replace_all(raw, r"(?is)<(style|script)\b.*?</(style|script)>", "");
    let brs = regex_replace_all(&no_style, r"(?i)<br\s*/?>", "\n");
    let hrs = regex_replace_all(&brs, r"(?i)<hr[^>]*>", "\n---\n");
    let text = regex_replace_all(&hrs, r"<[^>]+>", "");
    let text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    let text = regex_replace_all(&text, r"[ \t]+", " ");
    let text = regex_replace_all(&text, r"\n{3,}", "\n\n");
    text.trim().to_string()
}

fn regex_replace_all(input: &str, pattern: &str, replacement: &str) -> String {
    match regex::Regex::new(pattern) {
        Ok(re) => re.replace_all(input, replacement).to_string(),
        Err(_) => input.to_string(),
    }
}

fn split_answer(question: &str, answer: &str) -> String {
    // Anki's answer side repeats the question; keep only the back.
    if let Some(idx) = answer.find("---") {
        let tail = answer[idx + 3..].trim();
        if !tail.is_empty() {
            return tail.to_string();
        }
    }
    if let Some(rest) = answer.strip_prefix(question) {
        return rest.trim_start_matches(['-', '\n', ' ']).trim().to_string();
    }
    answer.to_string()
}
