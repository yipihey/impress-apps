#if os(macOS)
//
//  SurfaceDispatchReplyTests.swift
//  ImpressLayoutTests
//
//  A dispatch whose effect failed — a publish that found no pane, an `open`
//  Rust refused — answers `ok: false`, `code: "effect-failed"`, with the
//  re-rendered tree and each effect's own outcome and code (wave 7 T5,
//  reviews RS-S12, AC-F11). The pane decodes all of it (SK-K16).
//

import XCTest

@testable import ImpressLayout

final class SurfaceDispatchReplyTests: XCTestCase {

    func testAFailedEffectMakesTheReplyNotOkAndCarriesItsCode() throws {
        let reply = try SurfaceDispatchReply.decode(
            """
            {"ok": false, "code": "effect-failed",
             "message": "dispatched; 2 effect(s), 1 failed — publish: no pane shows this surface yet",
             "effects_failed": 1,
             "effects": [
               {"kind": "emit", "ok": true, "message": "emitted bins-chosen"},
               {"kind": "publish", "ok": false, "code": "no-pane",
                "message": "no pane shows this surface yet"}
             ]}
            """)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.code, "effect-failed")
        XCTAssertEqual(reply.effectsFailed, 1)
        XCTAssertNil(reply.tree)
        XCTAssertEqual(reply.effects.count, 2)
        XCTAssertEqual(reply.effects.filter { !$0.ok }.map(\.kind), ["publish"])
        XCTAssertEqual(reply.effects[1].code, "no-pane")
        XCTAssertNil(reply.effects[0].code)
    }

    func testARefusalWithoutEffectsDecodes() throws {
        let reply = try SurfaceDispatchReply.decode(
            #"{"ok": false, "code": "not-found", "message": "no surface x"}"#)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.code, "not-found")
        XCTAssertEqual(reply.effects, [])
        XCTAssertEqual(reply.effectsFailed, 0)
    }
}
#endif
