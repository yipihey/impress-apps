//
//  EInkToolbarStatusGlyph.swift
//  PublicationManagerCore
//
//  The small reMarkable status glyph in the window toolbar (ADR-025 P8):
//  connected / syncing / error / disconnected, driven by the connection
//  monitor (`EInkServices.shared.monitor`, `@Observable`) and the mirror
//  model's run state (`EInkMirrorModel.isSyncing`, set from the
//  coordinator's run-state callback). Renders nothing until a device is
//  configured.
//
//  It lives INSIDE the existing `.primaryAction` cluster in
//  `SectionContentView` — the fragile-toolbar rule (root CLAUDE.md): no new
//  toolbar placement, ever. Clicking it runs "Sync now"; the help text
//  says what it shows.
//
//  WHICH glyph for WHICH inputs is `EInkToolbarStatus`, a plain value.
//

import ImpressLogging
import OSLog
import SwiftUI

/// The glyph's four states, derived from three inputs.
public enum EInkToolbarStatus: String, Sendable, Equatable, CaseIterable {
    case syncing
    case error
    case connected
    case disconnected

    /// Syncing wins (it is an activity), then an error (the last run or the
    /// last upload failed), then the cable.
    public init(isSyncing: Bool, isConnected: Bool, hasError: Bool) {
        if isSyncing {
            self = .syncing
        } else if hasError {
            self = .error
        } else if isConnected {
            self = .connected
        } else {
            self = .disconnected
        }
    }

    public var systemImage: String {
        switch self {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .connected: return "rectangle.portrait.fill"
        case .disconnected: return "rectangle.portrait"
        }
    }

    public var help: String {
        switch self {
        case .syncing: return "Syncing with the reMarkable"
        case .error: return "The last reMarkable sync reported an error (see Settings › E-Ink)"
        case .connected: return "reMarkable connected over USB — click to sync now"
        case .disconnected: return "reMarkable not connected — click to check and sync"
        }
    }
}

struct EInkToolbarStatusGlyph: View {

    @State private var model = EInkMirrorModel.shared

    private var status: EInkToolbarStatus {
        let hasError = (model.status?.lastError).map { !$0.isEmpty } ?? false
            || (model.status?.counts.failed ?? 0) > 0
        return EInkToolbarStatus(
            isSyncing: model.isSyncing,
            isConnected: EInkServices.shared.monitor?.isConnected ?? false,
            hasError: hasError)
    }

    var body: some View {
        if model.isConfigured {
            let status = self.status
            Button {
                Logger.library.infoCapture("eink.toolbar glyph clicked (\(status.rawValue)) → sync now", category: "eink")
                Task { await EInkServices.shared.coordinator?.nudge(.manual) }
            } label: {
                Image(systemName: status.systemImage)
                    .foregroundStyle(tint(for: status))
                    .symbolEffect(.pulse, isActive: status == .syncing)
            }
            .disabled(status == .syncing)
            .help(status.help)
            .accessibilityLabel("reMarkable: \(status.rawValue)")
        }
    }

    private func tint(for status: EInkToolbarStatus) -> Color {
        switch status {
        case .syncing: return .accentColor
        case .error: return .red
        case .connected: return .green
        case .disconnected: return .secondary
        }
    }
}
