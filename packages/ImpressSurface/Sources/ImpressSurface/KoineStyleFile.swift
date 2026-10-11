//
//  KoineStyleFile.swift
//  ImpressSurface
//
//  `<workspace>/settings/koine-style.json`, the same document
//  `koine::style_file` reads. A missing file is the defaults. A file the
//  sheet would refuse is refused whole.
//

import Darwin
import Foundation

public enum KoineStyleFileError: Error, Equatable, LocalizedError {
    case version(Int)
    case unreadable(String)
    case style(KoineStyleError)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .version(let found):
            return "style file wire_version is \(found), and this build reads 1"
        case .unreadable(let detail):
            return "style file: \(detail)"
        case .style(let error):
            return error.localizedDescription
        case .io(let detail):
            return "style file: \(detail)"
        }
    }
}

public enum KoineStyleFile {
    public static let fileName = "koine-style.json"

    public static func url(workspace: URL) -> URL {
        workspace.appendingPathComponent("settings", isDirectory: true).appendingPathComponent(fileName)
    }

    /// A missing file is a default book. Anything `set` would refuse fails
    /// the whole file.
    public static func load(from url: URL) -> Result<KoineStyleBook, KoineStyleFileError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(KoineStyleBook())
        }
        do {
            let data = try Data(contentsOf: url)
            return .success(try book(from: data))
        } catch let error as KoineStyleFileError {
            return .failure(error)
        } catch {
            return .failure(.io(error.localizedDescription))
        }
    }

    public static func save(_ book: KoineStyleBook, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try encode(book)
        if let existing = try? Data(contentsOf: url), existing == data {
            return
        }
        try withLock(url) {
            let temporary = url.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        }
    }

    public static func book(from data: Data) throws -> KoineStyleBook {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object else {
            throw KoineStyleFileError.unreadable("the file is not an object")
        }
        let version = object["wire_version"] as? Int ?? 0
        guard version == 1 else {
            throw KoineStyleFileError.version(version)
        }
        guard let frontends = object["frontends"] as? [String: Any] else {
            throw KoineStyleFileError.unreadable("frontends is missing")
        }
        var book = KoineStyleBook()
        for (frontend, rawSlots) in frontends {
            guard let slots = rawSlots as? [String: String] else {
                throw KoineStyleFileError.unreadable("\(frontend) is not a map of strings")
            }
            for (slot, value) in slots {
                do {
                    try book.set(frontend: frontend, slot: slot, raw: value)
                } catch let error as KoineStyleError {
                    throw KoineStyleFileError.style(error)
                }
            }
        }
        return book
    }

    public static func encode(_ book: KoineStyleBook) throws -> Data {
        var frontends: [String: [String: String]] = [:]
        for frontend in KoineStyleSheet.frontendIDs {
            guard let sheet = book.sheet(frontend: frontend) else { continue }
            var slots: [String: String] = [:]
            for slot in KoineStyleSheet.slots(frontend: frontend) ?? [] {
                slots[slot.name] = sheet.value(slot.name)
            }
            frontends[frontend] = slots
        }
        let object: [String: Any] = [
            "wire_version": 1,
            "frontends": frontends,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return data + Data("\n".utf8)
    }

    private static func withLock(_ url: URL, _ body: () throws -> Void) throws {
        let lockPath = url.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if fd < 0 {
            throw KoineStyleFileError.io("could not open the lock")
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        if flock(fd, LOCK_EX) != 0 {
            throw KoineStyleFileError.io("could not lock the style file")
        }
        try body()
    }
}
