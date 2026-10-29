//! Another process wrote the store: wake the pages.
//!
//! SQLite events are per connection, so a write from the Swift app,
//! impress-mcp or the CLI never reaches koine-host's feed. Every impress
//! store write posts the Darwin note `impress_core::sqlite_store::
//! STORE_MUTATED_DARWIN_NOTE` (throttled to two a second, no payload); this
//! thread checks for it four times a second and hands each one to the host's
//! [`koine_host::feed::Waker`], which ignores the echo of the host's own
//! writes. A check is one syscall: there is nothing to debounce.

use std::time::Duration;

use koine_host::feed::Waker;

/// How often the note is checked: the most a page lags another app's write.
const CHECK: Duration = Duration::from_millis(250);

/// Start the listener thread for the life of the process. Off macOS there
/// is no note, and nothing starts.
pub fn listen(waker: Waker) {
    #[cfg(target_os = "macos")]
    {
        let spawned = std::thread::Builder::new()
            .name("imbib-host-elsewhere".into())
            .spawn(move || darwin::run(waker));
        if let Err(error) = spawned {
            tracing::warn!(target: "koine-host", "store note listener: {error}; \
                pages will not redraw on other apps' writes");
        }
    }
    #[cfg(not(target_os = "macos"))]
    drop(waker);
}

#[cfg(target_os = "macos")]
mod darwin {
    use std::ffi::CString;
    use std::os::raw::{c_char, c_int};

    use super::{Waker, CHECK};

    extern "C" {
        fn notify_register_check(name: *const c_char, out_token: *mut c_int) -> u32;
        fn notify_check(token: c_int, check: *mut c_int) -> u32;
    }

    pub(super) fn run(waker: Waker) {
        let name = CString::new(impress_core::sqlite_store::STORE_MUTATED_DARWIN_NOTE)
            .expect("the note name has no NUL");
        let mut token: c_int = 0;
        // SAFETY: `name` is NUL-terminated and outlives the call; `token`
        // is a valid out-pointer.
        let status = unsafe { notify_register_check(name.as_ptr(), &mut token) };
        if status != 0 {
            tracing::warn!(target: "koine-host", "store note listener: notify_register_check \
                answered {status}; pages will not redraw on other apps' writes");
            return;
        }
        // The first check after registering always reports a post.
        let mut posted: c_int = 0;
        // SAFETY: `token` came from notify_register_check; `posted` is valid.
        unsafe { notify_check(token, &mut posted) };
        tracing::info!(target: "koine-host", "store note listener: watching {}",
            impress_core::sqlite_store::STORE_MUTATED_DARWIN_NOTE);
        loop {
            std::thread::sleep(CHECK);
            posted = 0;
            // SAFETY: as above.
            if unsafe { notify_check(token, &mut posted) } != 0 || posted == 0 {
                continue;
            }
            if waker.store_changed_elsewhere() {
                tracing::info!(target: "koine-host", "store note: another process wrote the store; pages woken");
            } else {
                tracing::debug!(target: "koine-host", "store note: this host's own write, ignored");
            }
        }
    }
}
