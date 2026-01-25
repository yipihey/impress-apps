//
//  DatabasePreferenceStepView.swift
//  PublicationManagerCore
//
//  Onboarding step for choosing preferred literature database.
//

import SwiftUI

/// Onboarding step for choosing between OpenAlex and ADS as the preferred database.
///
/// Guides users through selecting their primary literature database source,
/// which sets the default enrichment source and guides the user experience.
public struct DatabasePreferenceStepView: View {

    // MARK: - Properties

    /// Binding to the user's database selection.
    @Binding var selection: PreferredDatabase

    /// Called when user continues to the next step.
    let onContinue: () -> Void

    // MARK: - Initialization

    public init(
        selection: Binding<PreferredDatabase>,
        onContinue: @escaping () -> Void
    ) {
        self._selection = selection
        self.onContinue = onContinue
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            headerSection

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Database selection cards
                    HStack(spacing: 16) {
                        DatabaseCard(
                            title: "OpenAlex",
                            isSelected: selection == .openAlex,
                            isRecommended: true,
                            icon: "book.pages",
                            color: .blue,
                            benefits: [
                                "Free access to 240M+ works",
                                "No account required",
                                "Open access status & metadata",
                                "Covers all research fields"
                            ]
                        ) {
                            selection = .openAlex
                        }

                        DatabaseCard(
                            title: "NASA ADS",
                            isSelected: selection == .ads,
                            isRecommended: false,
                            icon: "star.fill",
                            color: .orange,
                            benefits: [
                                "Best for astronomy & physics",
                                "Deep field-specific coverage",
                                "Easy to get a free account",
                                "Great if you already use ADS"
                            ]
                        ) {
                            selection = .ads
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)

                    // Footer note
                    Text("You can always change this later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Divider()

            // Buttons
            buttonSection
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "building.columns")
                    .font(.title)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Your Literature Database")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Select your preferred source for paper metadata and citations")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
    }

    // MARK: - Button Section

    private var buttonSection: some View {
        HStack {
            Spacer()

            Button {
                onContinue()
            } label: {
                Text("Continue")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }
}

// MARK: - Database Card

/// A selectable card representing a database option.
private struct DatabaseCard: View {

    let title: String
    let isSelected: Bool
    let isRecommended: Bool
    let icon: String
    let color: Color
    let benefits: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                // Header with icon and title
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(color)

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                    }
                }

                // Recommended badge
                if isRecommended {
                    Text("Recommended for most users")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(color)
                        )
                }

                Divider()

                // Benefits list
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(benefits, id: \.self) { benefit in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(color)
                                .frame(width: 16)

                            Text(benefit)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? color.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? color : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    DatabasePreferenceStepView(
        selection: .constant(.openAlex),
        onContinue: { }
    )
    .frame(width: 550, height: 500)
}

#Preview("ADS Selected") {
    DatabasePreferenceStepView(
        selection: .constant(.ads),
        onContinue: { }
    )
    .frame(width: 550, height: 500)
}
