//
//  AssignmentListView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import SwiftUI
import CoreData
import OSLog

// MARK: - Assignment List View

/// Shows all reading suggestions for a shared library.
///
/// Assignments are grouped into "For You" and "All Suggestions".
/// Each shows the paper title, who suggested it, optional note,
/// and optional due date. No completion tracking.
public struct AssignmentListView: View {
    let library: CDLibrary

    @State private var assignments: [CDAssignment] = []
    @Environment(\.dismiss) private var dismiss

    public init(library: CDLibrary) {
        self.library = library
    }

    public var body: some View {
        NavigationStack {
            List {
                let myAssignments = AssignmentService.shared.myAssignments(in: library)
                let allAssignments = AssignmentService.shared.assignments(in: library)

                if myAssignments.isEmpty && allAssignments.isEmpty {
                    ContentUnavailableView(
                        "No Suggestions",
                        systemImage: "bookmark",
                        description: Text("Use \"Suggest to...\" on any paper to recommend it to a collaborator.")
                    )
                } else {
                    if !myAssignments.isEmpty {
                        Section("For You") {
                            ForEach(myAssignments, id: \.id) { assignment in
                                AssignmentRow(assignment: assignment, showAssignee: false)
                            }
                            .onDelete { offsets in
                                deleteAssignments(at: offsets, from: myAssignments)
                            }
                        }
                    }

                    Section("All Suggestions") {
                        ForEach(allAssignments, id: \.id) { assignment in
                            AssignmentRow(assignment: assignment, showAssignee: true)
                        }
                        .onDelete { offsets in
                            deleteAssignments(at: offsets, from: allAssignments)
                        }
                    }
                }
            }
            .navigationTitle("Reading Suggestions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                assignments = AssignmentService.shared.assignments(in: library)
            }
        }
    }

    private func deleteAssignments(at offsets: IndexSet, from list: [CDAssignment]) {
        for index in offsets {
            let assignment = list[index]
            try? AssignmentService.shared.remove(assignment)
        }
        assignments = AssignmentService.shared.assignments(in: library)
    }
}

// MARK: - Assignment Row

private struct AssignmentRow: View {
    let assignment: CDAssignment
    let showAssignee: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Paper title
            Text(assignment.publication?.title ?? "Unknown Paper")
                .font(.body)
                .lineLimit(2)

            // Metadata line
            HStack(spacing: 8) {
                if showAssignee, let assignee = assignment.assigneeName {
                    Label(assignee, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let suggestor = assignment.assignedByName {
                    Text("from \(suggestor)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Note
            if let note = assignment.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            // Due date
            if let dueDate = assignment.dueDate {
                Label(dueDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .font(.caption2)
                    .foregroundStyle(dueDate < Date() ? .red : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Suggest To Sheet

/// Sheet for suggesting a paper to a participant.
public struct SuggestToSheet: View {
    let publication: CDPublication
    let library: CDLibrary

    @State private var selectedParticipant: String = ""
    @State private var note: String = ""
    @State private var dueDate: Date?
    @State private var showDatePicker = false
    @State private var participantNames: [String] = []
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    public init(publication: CDPublication, library: CDLibrary) {
        self.publication = publication
        self.library = library
    }

    public var body: some View {
        NavigationStack {
            Form {
                // Paper being suggested
                Section("Paper") {
                    Text(publication.title ?? "Untitled")
                        .font(.body)
                        .lineLimit(3)
                }

                // Participant picker
                Section("Suggest to") {
                    if participantNames.isEmpty {
                        Text("No other participants in this library")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Participant", selection: $selectedParticipant) {
                            Text("Select...").tag("")
                            ForEach(participantNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        #if os(iOS)
                        .pickerStyle(.menu)
                        #endif
                    }
                }

                // Optional note
                Section("Note (optional)") {
                    TextField("For Friday's meeting...", text: $note)
                }

                // Optional due date
                Section {
                    Toggle("Set due date", isOn: $showDatePicker)
                    if showDatePicker {
                        DatePicker("Due date", selection: Binding(
                            get: { dueDate ?? Date().addingTimeInterval(7 * 86400) },
                            set: { dueDate = $0 }
                        ), displayedComponents: .date)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Suggest Paper")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Suggest") {
                        createAssignment()
                    }
                    .disabled(selectedParticipant.isEmpty)
                }
            }
            .onAppear {
                participantNames = AssignmentService.shared.participantNames(in: library)
                if let first = participantNames.first {
                    selectedParticipant = first
                }
            }
        }
    }

    private func createAssignment() {
        do {
            try AssignmentService.shared.suggest(
                publication: publication,
                to: selectedParticipant,
                in: library,
                note: note.isEmpty ? nil : note,
                dueDate: showDatePicker ? dueDate : nil
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
