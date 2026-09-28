#!/bin/bash
# Apple app images must share the platform SQLite library. Xcode may emit
# separate Swift package frameworks, so bundling SQLite into each Rust
# archive gives one process independent copies of SQLite's file-lock state.
# See https://www.sqlite.org/howtocorrupt.html#multiple_copies_of_sqlite_linked_into_the_same_application
# libsqlite3-sys explicitly supports this linked-build override even when
# Cargo's bundled feature is enabled. CLI/test builds outside these scripts
# keep their existing bundled dependency; no Cargo feature is changed here.
export LIBSQLITE3_SYS_USE_PKG_CONFIG=1
# Prevent Homebrew or a caller's custom path from substituting another copy.
export SQLITE3_NO_PKG_CONFIG=1
export SQLITE3_STATIC=0
unset SQLITE3_LIB_DIR SQLITE3_INCLUDE_DIR
