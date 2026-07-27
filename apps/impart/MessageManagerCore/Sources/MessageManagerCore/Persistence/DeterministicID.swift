//
//  DeterministicID.swift
//  MessageManagerCore
//
//  Deterministic UUIDv5 identifiers for unified-store rows (GUI unification
//  Stage 0 WP3). The shared store requires item ids to be UUID strings; mail
//  rows derive theirs deterministically from stable mail identity so that
//  dual-writes, backfill re-runs, and cross-process writers all converge on
//  the same row.
//
//  ID scheme (inputs lowercased before hashing, ids emitted lowercased):
//
//  | Item kind | Name hashed |
//  |---|---|
//  | email-message | RFC-822 Message-ID; fallback: CDMessage.objectID URI |
//  | mail-account  | account address (fallback: display name) |
//  | mail-folder   | "<account address>/<remote path or name>" |
//

import CryptoKit
import Foundation

/// Namespaced UUIDv5 (RFC 4122 §4.3, SHA-1 based) derivation for the
/// impress unified store.
public enum DeterministicID {

    /// Fixed namespace for every impart-owned item in the shared store.
    ///
    /// Derived ONCE as `UUIDv5(NAMESPACE_DNS, "store.impress.impart")` and
    /// hardcoded here. Never change this constant — every deterministic
    /// item id in every user's store depends on it.
    public static let impartNamespace = UUID(uuidString: "74E0F579-4A0D-5799-AA19-E450F3CDC08B")!

    /// The RFC 4122 DNS namespace, exposed for verification tests.
    public static let dnsNamespace = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

    // MARK: - Core derivation

    /// RFC 4122 name-based UUID, version 5 (SHA-1).
    public static func uuidV5(namespace: UUID, name: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(name.utf8))
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes))).prefix(16).map { $0 }
        digest[6] = (digest[6] & 0x0F) | 0x50   // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// Lowercased UUIDv5 string in the impart namespace. `name` is
    /// lowercased before hashing so case variants of the same identity
    /// converge on one row.
    public static func itemID(for name: String) -> String {
        uuidV5(namespace: impartNamespace, name: name.lowercased())
            .uuidString.lowercased()
    }

    // MARK: - Mail identities

    /// Item id for an email message. Uses the RFC-822 Message-ID when
    /// present; falls back to the Core Data objectID URI otherwise.
    public static func messageItemID(messageID: String?, fallbackURI: String) -> String {
        let trimmed = messageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return itemID(for: trimmed.isEmpty ? fallbackURI : trimmed)
    }

    /// Item id for a mail account, keyed by address (fallback: name).
    public static func accountItemID(address: String, name: String = "") -> String {
        itemID(for: address.isEmpty ? name : address)
    }

    /// Item id for a mail folder, keyed by `"<account>/<remote path or name>"`.
    public static func folderItemID(accountKey: String, remotePath: String, name: String = "") -> String {
        let path = remotePath.isEmpty ? name : remotePath
        return itemID(for: "\(accountKey)/\(path)")
    }
}
