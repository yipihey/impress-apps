#if os(macOS)
//
//  SurfaceDispatchReplyTests.swift
//  ImpressLayoutTests
//
//  `surface_dispatch` can answer `ok` while an effect failed — a publish
//  that found no pane, an `open` Rust refused. The pane now decodes the
//  per-effect outcomes so it can say so (review SK-K16); it used to decode
//  `ok`/`message`/`tree` only and log `ok=true`.
//

import XCTest

@testable import ImpressLayout

final class SurfaceDispatchReplyTests: XCTestCase {

    func testEffectsAreDecodedWithTheirOutcome() throws {
        let reply = try SurfaceDispatchReply.decode(
            """
            {"ok": true, "message": "dispatched; 2 effect(s)",
             "effects": [
               {"kind": "emit", "ok": true, "message": "emitted bins-chosen"},
               {"kind": "publish", "ok": false, "message": "no pane shows this surface yet"}
             ]}
            """)
        XCTAssertTrue(reply.ok)
        XCTAssertNil(reply.tree)
        XCTAssertEqual(reply.effects.count, 2)
        XCTAssertEqual(reply.effects.filter { !$0.ok }.map(\.kind), ["publish"])
    }

    func testAReplyWithoutEffectsDecodes() throws {
        let reply = try SurfaceDispatchReply.decode(#"{"ok": false, "message": "no such surface"}"#)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.effects, [])
    }
}
#endif
