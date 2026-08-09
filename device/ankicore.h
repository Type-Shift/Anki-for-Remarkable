#ifndef ANKICORE_H
#define ANKICORE_H

// C interface to Anki's own Rust backend (rslib), built from device/ankicore.
//
// Every call returns a JSON string the caller owns and must release with
// ankicore_free_string. Success is {"ok":true,...}; failure is
// {"ok":false,"error":"..."}.
//
// JSON rather than rslib's protobuf service interface: the app already parses
// JSON and these payloads are tiny, so a protobuf runtime would be dead weight.

#ifdef __cplusplus
extern "C" {
#endif

/// Version of the linked rslib. Proves what actually shipped.
char *ankicore_version(void);

/// Open (creating if absent) the collection at `path`.
char *ankicore_open(const char *path);

/// Close the collection, flushing to disk.
char *ankicore_close(void);

/// Deck tree with the counts Anki itself would show, honouring daily limits.
char *ankicore_deck_list(void);

/// The next card the scheduler would show for `deck_id`, as plain text with
/// the four button labels Anki would print.
char *ankicore_next_card(long long deck_id);

/// Answer the current card. `rating` is 1..4 (Again, Hard, Good, Easy).
char *ankicore_answer_card(long long card_id, int rating, int milliseconds_taken);

/// Release a string returned by any of the above.
void ankicore_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif // ANKICORE_H
