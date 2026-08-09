//! C shim over Anki's own Rust backend (rslib).
//!
//! The tablet currently replays interval labels that Anki computed on the PC
//! at export time. That is close, but it is not parity: the device cannot
//! work out what an interval becomes after a learning step, so a card taken
//! through several steps lands where its final grade puts it rather than
//! where Anki's own progression would.
//!
//! Linking rslib removes the approximation entirely: the same scheduler, the
//! same collection format, the same sync client as the desktop.
//!
//! This first cut deliberately proves only the hard part -- that rslib
//! cross-compiles for armv7 and can open a collection on the device. The
//! richer API (deck list, next card, answer, sync) follows once that holds.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

/// Version of the linked rslib, for confirming what actually shipped.
/// Caller must free with `ankicore_free_string`.
#[no_mangle]
pub extern "C" fn ankicore_version() -> *mut c_char {
    let v = anki::version::version();
    match CString::new(v) {
        Ok(s) => s.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Open (creating if absent) a collection, then close it.
/// Returns 0 on success, non-zero on failure.
///
/// Proves the SQLite bundle, the schema migrations and the file layout all
/// work on the device, which is where a cross-compiled build is most likely
/// to fall over.
#[no_mangle]
pub extern "C" fn ankicore_selftest(path: *const c_char) -> c_int {
    if path.is_null() {
        return -1;
    }
    let path = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(p) => p.to_owned(),
        Err(_) => return -2,
    };

    match anki::collection::CollectionBuilder::new(path).build() {
        Ok(mut col) => {
            // Touch the scheduler so the probe covers more than file IO.
            let _ = col.timing_today();
            match col.close(None) {
                Ok(_) => 0,
                Err(_) => 3,
            }
        }
        Err(_) => 4,
    }
}

/// Free a string returned by this library.
#[no_mangle]
pub extern "C" fn ankicore_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}
