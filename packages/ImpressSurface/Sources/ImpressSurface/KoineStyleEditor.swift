//
//  KoineStyleEditor.swift
//  ImpressSurface
//
//  A native editor for one frontend's sheet. A color or a font is a picker
//  of the legal tokens. Spacing is a stepper. A line is a field. Every
//  change calls the same `set` and `reset` as `koine::style::editor_apply`,
//  then `onStored` so the host can write the file.
//
//  No `.focusable()` on this container: the text fields are the focus.
//

import SwiftUI

public struct KoineStyleEditor: View {
    @Binding private var book: KoineStyleBook
    private let frontend: String
    private let onStored: (KoineStyleBook) -> Void
    @State private var drafts: [String: String] = [:]
    @State private var problem: String?

    public init(
        book: Binding<KoineStyleBook>,
        frontend: String = KoineStyleSheet.swiftID,
        onStored: @escaping (KoineStyleBook) -> Void = { _ in }
    ) {
        _book = book
        self.frontend = frontend
        self.onStored = onStored
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(frontend)
                .font(.headline)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let slots = KoineStyleSheet.slots(frontend: frontend) {
                ForEach(slots, id: \.name) { slot in
                    slotRow(slot)
                }
            } else {
                Text("unknown frontend '\(frontend)'")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { syncLineDrafts() }
    }

    @ViewBuilder
    private func slotRow(_ slot: KoineSlot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name)
                Text(slot.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 140, alignment: .leading)
            control(slot)
            Button("Reset") { reset(slot) }
        }
    }

    @ViewBuilder
    private func control(_ slot: KoineSlot) -> some View {
        switch slot.kind {
        case .color:
            tokenPicker(slot, tokens: KoineStyleSheet.colorTokens)
        case .font:
            tokenPicker(slot, tokens: KoineStyleSheet.fontTokens)
        case .spacing:
            Stepper(value: spacingBinding(slot), in: 0...KoineStyleSheet.spacingMax) {
                Text(book.sheet(frontend: frontend)?.value(slot.name) ?? slot.defaultValue)
                    .monospacedDigit()
            }
        case .line:
            TextField(slot.defaultValue, text: draftBinding(slot.name))
                .onSubmit { commitLine(slot) }
            Button("Set") { commitLine(slot) }
        }
    }

    private func tokenPicker(_ slot: KoineSlot, tokens: [String]) -> some View {
        Picker(slot.name, selection: tokenBinding(slot)) {
            ForEach(tokens, id: \.self) { token in
                Text(token).tag(token)
            }
        }
        .labelsHidden()
    }

    private func tokenBinding(_ slot: KoineSlot) -> Binding<String> {
        Binding(
            get: { book.sheet(frontend: frontend)?.value(slot.name) ?? slot.defaultValue },
            set: { store(slot, $0) }
        )
    }

    private func spacingBinding(_ slot: KoineSlot) -> Binding<Int> {
        Binding(
            get: { Int(book.sheet(frontend: frontend)?.value(slot.name) ?? "") ?? 0 },
            set: { store(slot, String($0)) }
        )
    }

    private func draftBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { drafts[name] ?? "" },
            set: { drafts[name] = $0 }
        )
    }

    private func syncLineDrafts() {
        guard let sheet = book.sheet(frontend: frontend) else { return }
        var next: [String: String] = [:]
        for slot in (KoineStyleSheet.slots(frontend: frontend) ?? []).filter({ $0.kind == .line }) {
            next[slot.name] = sheet.value(slot.name)
        }
        drafts = next
    }

    private func store(_ slot: KoineSlot, _ raw: String) {
        do {
            try book.set(frontend: frontend, slot: slot.name, raw: raw)
            problem = nil
            onStored(book)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func commitLine(_ slot: KoineSlot) {
        store(slot, drafts[slot.name] ?? "")
    }

    private func reset(_ slot: KoineSlot) {
        do {
            try book.reset(frontend: frontend, slot: slot.name)
            problem = nil
            if slot.kind == .line, let sheet = book.sheet(frontend: frontend) {
                drafts[slot.name] = sheet.value(slot.name)
            }
            onStored(book)
        } catch {
            problem = error.localizedDescription
        }
    }
}
