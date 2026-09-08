import SwiftUI

/// The model picker shared by Settings › AI and the quick switcher: one row
/// per model with what the host reports — friendly name, raw id, load state,
/// context window, output limit, vision, the server's own default — and
/// helper pseudo-models hidden unless asked for (they are never selectable).
///
/// The rows render inline, never inside a nested `List`: a scroll view inside
/// a grouped `Form` on macOS does not reliably scroll, and a bounded one hid
/// the rows past its frame. Inline rows let the form itself scroll past every
/// model; a filter field appears once the list is long.
public struct AIModelPickerList: View {
    /// Above this many visible models a filter field is shown.
    public static let filterThreshold = 8

    private let models: [AIModel]
    @Binding private var selection: String?
    private let showHelpers: Bool
    private let compact: Bool
    /// When set, each row gets a checkbox for "available to the impress
    /// apps", which is what the per-task pickers then offer.
    private let isEnabled: ((AIModel) -> Bool)?
    private let onToggleEnabled: ((AIModel, Bool) -> Void)?
    @State private var query = ""

    /// - Parameters:
    ///   - models: Every model the provider offers, helpers included.
    ///   - selection: The selected model id.
    ///   - showHelpers: Whether helper pseudo-models are listed (disabled).
    ///   - compact: Single-line rows for menus and popovers.
    public init(
        models: [AIModel],
        selection: Binding<String?>,
        showHelpers: Bool = false,
        compact: Bool = false,
        isEnabled: ((AIModel) -> Bool)? = nil,
        onToggleEnabled: ((AIModel, Bool) -> Void)? = nil
    ) {
        self.models = models
        self._selection = selection
        self.showHelpers = showHelpers
        self.compact = compact
        self.isEnabled = isEnabled
        self.onToggleEnabled = onToggleEnabled
    }

    /// The rows the list shows: helpers only on request, then the filter.
    /// Pure so tests can pin it; the selected model always stays visible so a
    /// filter never hides what is in effect.
    public static func visibleModels(
        _ models: [AIModel],
        showHelpers: Bool,
        query: String,
        selection: String?
    ) -> [AIModel] {
        let candidates = showHelpers ? models : models.filter { !$0.isHelper }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { model in
            model.id == selection
                || model.name.lowercased().contains(needle)
                || model.id.lowercased().contains(needle)
        }
    }

    private var listedModels: [AIModel] {
        showHelpers ? models : models.filter { !$0.isHelper }
    }

    private var visibleModels: [AIModel] {
        Self.visibleModels(models, showHelpers: showHelpers, query: query, selection: selection)
    }

    private var showsFilter: Bool {
        listedModels.count > Self.filterThreshold
    }

    public var body: some View {
        if listedModels.isEmpty {
            Text("No models available")
                .foregroundStyle(.secondary)
        } else {
            if showsFilter {
                TextField("Filter models", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ai.model.filter")
            }
            if visibleModels.isEmpty {
                Text("No model matches “\(query)”")
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleModels) { model in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let isEnabled, let onToggleEnabled {
                        Toggle(
                            "Available to the impress apps",
                            isOn: Binding(
                                get: { isEnabled(model) },
                                set: { onToggleEnabled(model, $0) })
                        )
                        .labelsHidden()
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                        .disabled(model.isHelper)
                        .accessibilityIdentifier("ai.model.enabled.\(model.id)")
                    }

                    Button {
                        guard !model.isHelper else { return }
                        selection = model.id
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: selection == model.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == model.id ? Color.accentColor : Color.secondary)
                                .accessibilityHidden(true)
                            AIModelRow(model: model, compact: compact)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isHelper)
                    .accessibilityAddTraits(selection == model.id ? [.isSelected] : [])
                    .accessibilityIdentifier("ai.model.\(model.id)")
                }
            }
        }
    }

    /// The footer line a settings pane shows under the list.
    public static func summary(models: [AIModel], refreshedAt: Date?) -> String {
        let helpers = models.filter(\.isHelper).count
        let usable = models.count - helpers
        var parts = ["\(usable) \(usable == 1 ? "model" : "models")"]
        if helpers > 0 {
            parts.append("\(helpers) \(helpers == 1 ? "helper" : "helpers") hidden")
        }
        if let refreshedAt {
            parts.append("refreshed \(refreshedAt.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: " · ")
    }
}

/// One model row: name, badges, and the raw id underneath.
public struct AIModelRow: View {
    private let model: AIModel
    private let compact: Bool

    public init(model: AIModel, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            HStack(spacing: 6) {
                Text(model.name)
                    .foregroundStyle(model.isHelper ? .secondary : .primary)
                if !compact {
                    badges
                }
            }
            if compact {
                HStack(spacing: 6) {
                    badges
                }
            } else if model.name != model.id {
                Text(model.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, compact ? 0 : 2)
    }

    @ViewBuilder
    private var badges: some View {
        if let isLoaded = model.isLoaded {
            AIModelBadge(
                text: isLoaded ? "Loaded" : "Not loaded",
                systemImage: "circle.fill",
                tint: isLoaded ? .green : .secondary
            )
        }
        if let contextWindow = model.contextWindow {
            AIModelBadge(text: "\(Self.compactNumber(contextWindow)) ctx", systemImage: "text.alignleft", tint: .secondary)
        }
        if let maxOutput = model.maxOutputTokens {
            AIModelBadge(text: "\(Self.compactNumber(maxOutput)) out", systemImage: "arrow.right", tint: .secondary)
        }
        if model.capabilities?.contains(.vision) == true {
            AIModelBadge(text: "Vision", systemImage: "eye", tint: .blue)
        }
        if model.isServerDefault {
            AIModelBadge(text: "Server default", systemImage: "star.fill", tint: .orange)
        }
        if model.isHelper {
            AIModelBadge(text: "Helper", systemImage: "wrench.and.screwdriver", tint: .secondary)
        }
    }

    static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return "\(value / 1_000)K"
        }
        return "\(value)"
    }
}

struct AIModelBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
            .labelStyle(.titleAndIcon)
    }
}
