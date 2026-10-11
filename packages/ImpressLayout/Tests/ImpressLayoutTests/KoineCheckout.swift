#if os(macOS)
import Foundation

/// A file from the koine checkout this workspace pins in `Cargo.lock`.
/// The grammar has one home. `cargo fetch` is what materialises it.
enum KoineCheckout {
    static func file(_ relative: String) throws -> URL {
        let lockURL = repoRoot().appendingPathComponent("Cargo.lock")
        let lock = try String(contentsOf: lockURL, encoding: .utf8)
        guard let rev = revision(in: lock) else {
            throw failure("Cargo.lock does not pin https://github.com/yipihey/koine")
        }
        let cargoHome = ProcessInfo.processInfo.environment["CARGO_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo")
        let checkouts = cargoHome.appendingPathComponent("git/checkouts", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: checkouts, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix("koine-") {
            let subs = (try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil)) ?? []
            for sub in subs where rev.hasPrefix(sub.lastPathComponent) {
                let file = sub.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: file.path) {
                    return file
                }
            }
        }
        throw failure(
            "no checkout of koine \(rev) contains \(relative); run cargo fetch in the impress-apps checkout"
        )
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func revision(in lock: String) -> String? {
        guard let range = lock.range(of: "git+https://github.com/yipihey/koine") else {
            return nil
        }
        let rest = lock[range.upperBound...]
        guard let hash = rest.firstIndex(of: "#") else { return nil }
        let start = rest.index(after: hash)
        let end = rest[start...].firstIndex(where: { $0 == "\"" || $0.isNewline }) ?? rest.endIndex
        let rev = String(rest[start..<end])
        return rev.isEmpty ? nil : rev
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "KoineCheckout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
