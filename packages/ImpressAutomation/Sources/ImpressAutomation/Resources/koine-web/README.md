# koine-web bundle

This folder is served as `GET /ui/*` by every impress app's automation server
(`KoineWebRoutes`). It holds the browser build of koine's Dioxus frontend
(`crates/koine-web` in the koine repository, `docs/plan-koine-web.md` D9):
`index.html`, `wasm/koine-web.js`, `wasm/koine-web_bg.wasm` and `assets/`.

The bundle is not committed. `scripts/build-koine-web.sh` builds it with
`dx build --platform web --release` and copies it here; until it has run,
`/ui/` answers 503 naming that script. SwiftPM copies this folder as-is
(`.copy("Resources/koine-web")` in Package.swift), so this README is the one
file that is always present.
