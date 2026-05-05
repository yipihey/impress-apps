//
//  CurrentDeviceAuthor.swift
//  ImpressKit
//
//  Platform-appropriate "who am I" for author-stamped records.
//
//  Rule 7 of ADR-023 (iOS/macOS parity protocol) says platform-scoped
//  code should live in the target it belongs to, not deep inside a
//  shared data-layer package. `PublicationManagerCore.RustStoreAdapter`
//  previously reached for `Host.current().localizedName` on macOS and
//  `UIDevice.current.name` on iOS to stamp comments, assignments, and
//  suggestions. That pattern required every `import Foundation`-only
//  file in the package to also guard a UIKit import just in case, and
//  it tied the data layer to UI frameworks.
//
//  The new pattern: app targets query `CurrentDeviceAuthor.displayName`
//  (this helper) at the call site and pass the result to the data
//  layer as an explicit `authorDisplayName:` parameter. The data
//  layer never touches `UIKit` or `AppKit` again.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Platform-appropriate display name for the current device's author.
///
/// On macOS this is the Bonjour-style host name
/// (`Host.current().localizedName`). On iOS it is `UIDevice.current.name`.
/// Both are user-editable in System Settings / Settings.app and are
/// appropriate for stamping comments, assignments, and activity
/// records with a recognizable identity.
///
/// The result is optional because both platforms' APIs can return
/// `nil` in tightly-sandboxed environments. Callers should pass the
/// value straight through to the data layer; the data layer treats
/// `nil` as "unknown author" and stores it as such.
public enum CurrentDeviceAuthor {

    /// The display name for the current device, suitable for
    /// stamping records with a human-readable origin.
    public static var displayName: String? {
        #if os(macOS)
        return Host.current().localizedName
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return nil
        #endif
    }
}
