# Imprint critical invariants

- A native create or edit verb succeeds only after the manuscript is saved to the GUI's exact `SharedWorkspace.databasePath` and read back there. A queued `DocumentRegistry` operation is not evidence of a save; the legacy HTTP create handler only returned a prospective ID.
- Text edits derive from the shared live `ManuscriptEditorSession.source`, including pending human changes, and commit through that session before reporting success. The editor owns its undo stack.
- Automation text offsets and comment `TextRange` offsets are UTF-16 `NSRange` positions. The comment store converts them to UTF-8 byte anchors for persistence.
- Native async verb dispatch must run on the shared Tokio runtime; Swift's UniFFI executor supplies no Tokio reactor. The hosted Typst compile proof must produce a real PDF without blocking the main actor.
- Manuscript list/get use the exact store installed for the native host. A store error or wrong-kind ID must propagate through the refusal channel rather than becoming a successful empty result.
