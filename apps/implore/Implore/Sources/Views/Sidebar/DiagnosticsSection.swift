import SwiftUI
import ImploreCore

/// Diagnostics section for analyzing generated/loaded data
struct DiagnosticsSection: View {
    @Environment(AppState.self) var appState
    @Environment(GeneratorViewModel.self) var generatorViewModel
    @State private var selectedDiagnostic: DiagnosticType = .statistics

    var body: some View {
        VStack(spacing: 0) {
            // Diagnostic type picker
            Picker("Diagnostic", selection: $selectedDiagnostic) {
                ForEach(DiagnosticType.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Content based on diagnostic type
            ScrollView {
                switch selectedDiagnostic {
                case .statistics:
                    StatisticsView()
                case .powerSpectrum:
                    PowerSpectrumView()
                case .histogram:
                    HistogramView()
                }
            }
        }
        .accessibilityIdentifier("sidebar.diagnosticsSection")
    }
}

/// Types of diagnostics available
enum DiagnosticType: String, CaseIterable {
    case statistics
    case powerSpectrum
    case histogram

    var title: String {
        switch self {
        case .statistics: return "Stats"
        case .powerSpectrum: return "Spectrum"
        case .histogram: return "Histogram"
        }
    }
}

/// Statistics view showing basic data statistics
struct StatisticsView: View {
    @Environment(GeneratorViewModel.self) var generatorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = generatorViewModel.dataSummary {
                // Data overview
                Section {
                    StatRow(label: "Points", value: summary.formattedPointCount)
                    StatRow(label: "Columns", value: "\(summary.columnCount)")
                    StatRow(label: "Has Bounds", value: summary.hasBounds ? "Yes" : "No")
                } header: {
                    SectionHeader(title: "Overview", icon: "info.circle")
                }

                // Column list
                Section {
                    ForEach(summary.columnNames, id: \.self) { name in
                        ColumnStatRow(name: name)
                    }
                } header: {
                    SectionHeader(title: "Columns", icon: "tablecells")
                }
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Generate or load data to view statistics")
                )
            }
        }
        .padding(12)
    }
}

/// Power spectrum analysis view
struct PowerSpectrumView: View {
    @Environment(GeneratorViewModel.self) var generatorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if generatorViewModel.generatedData != nil {
                Section {
                    // Placeholder for power spectrum plot
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(height: 200)
                        .overlay {
                            VStack {
                                Image(systemName: "waveform.path.ecg")
                                    .font(.largeTitle)
                                    .foregroundStyle(.tertiary)
                                Text("Power Spectrum")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                    // Spectrum info
                    Text("1D power spectrum analysis")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                } header: {
                    SectionHeader(title: "Radial Average", icon: "waveform")
                }

                Section {
                    HStack {
                        Text("Slope")
                        Spacer()
                        Text("--")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Intercept")
                        Spacer()
                        Text("--")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Spectral Index")
                        Spacer()
                        Text("--")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    SectionHeader(title: "Power Law Fit", icon: "chart.line.uptrend.xyaxis")
                }
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "waveform.slash",
                    description: Text("Generate data to analyze its power spectrum")
                )
            }
        }
        .padding(12)
    }
}

/// Histogram view for distribution analysis
struct HistogramView: View {
    @Environment(GeneratorViewModel.self) var generatorViewModel
    @State private var selectedColumn: String?
    @State private var binCount: Int = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = generatorViewModel.dataSummary {
                // Column selector
                Section {
                    Picker("Column", selection: $selectedColumn) {
                        Text("Select...").tag(nil as String?)
                        ForEach(summary.columnNames, id: \.self) { name in
                            Text(name).tag(name as String?)
                        }
                    }

                    Stepper("Bins: \(binCount)", value: $binCount, in: 10...200, step: 10)
                } header: {
                    SectionHeader(title: "Settings", icon: "slider.horizontal.3")
                }

                // Histogram plot
                Section {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(height: 200)
                        .overlay {
                            if selectedColumn != nil {
                                VStack {
                                    Image(systemName: "chart.bar")
                                        .font(.largeTitle)
                                        .foregroundStyle(.tertiary)
                                    Text("Histogram")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Select a column")
                                    .foregroundStyle(.secondary)
                            }
                        }
                } header: {
                    SectionHeader(title: "Distribution", icon: "chart.bar")
                }

                // Stats for selected column
                if selectedColumn != nil {
                    Section {
                        StatRow(label: "Min", value: "--")
                        StatRow(label: "Max", value: "--")
                        StatRow(label: "Mean", value: "--")
                        StatRow(label: "Std Dev", value: "--")
                        StatRow(label: "Median", value: "--")
                    } header: {
                        SectionHeader(title: "Statistics", icon: "sum")
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Generate data to view histograms")
                )
            }
        }
        .padding(12)
    }
}

// MARK: - Helper Views

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .fontWeight(.semibold)
        }
        .font(.subheadline)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.callout)
    }
}

struct ColumnStatRow: View {
    let name: String

    var body: some View {
        HStack {
            Text(name)
                .fontWeight(.medium)
            Spacer()
            Text("Float64")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    DiagnosticsSection()
        .environment(AppState())
        .environment(GeneratorViewModel())
        .frame(width: 280, height: 600)
}
