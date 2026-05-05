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
                case .plots:
                    DataSeriesPlotSection()
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
    case plots
    case powerSpectrum
    case histogram

    var title: String {
        switch self {
        case .statistics: return "Stats"
        case .plots: return "Plots"
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

/// Histogram view for distribution analysis — supports both generated data and RG volumes
struct HistogramView: View {
    @Environment(AppState.self) var appState
    @Environment(GeneratorViewModel.self) var generatorViewModel
    @State private var selectedColumn: String?
    @State private var binCount: Int = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // RG volume histogram (real data)
            if let plotState = appState.plotViewerState, appState.rgViewerState?.info.hasVolumeData == true {
                Section {
                    Picker("Quantity", selection: Binding(
                        get: { plotState.histogramField },
                        set: { plotState.histogramField = $0 }
                    )) {
                        ForEach(plotState.info.availableQuantities, id: \.self) { q in
                            Text(q).tag(q)
                        }
                    }

                    Stepper(
                        "Bins: \(plotState.histogramBins == 0 ? "auto" : "\(plotState.histogramBins)")",
                        value: Binding(
                            get: { plotState.histogramBins },
                            set: { plotState.histogramBins = $0 }
                        ),
                        in: 0...200,
                        step: 10
                    )
                } header: {
                    SectionHeader(title: "Field Histogram", icon: "slider.horizontal.3")
                }

                Button {
                    plotState.renderHistogram()
                    appState.showingPlotView = true
                } label: {
                    Label("Compute Histogram", systemImage: "chart.bar")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Generated data histogram (placeholder)
            if let summary = generatorViewModel.dataSummary {
                Section {
                    Picker("Column", selection: $selectedColumn) {
                        Text("Select...").tag(nil as String?)
                        ForEach(summary.columnNames, id: \.self) { name in
                            Text(name).tag(name as String?)
                        }
                    }

                    Stepper("Bins: \(binCount)", value: $binCount, in: 10...200, step: 10)
                } header: {
                    SectionHeader(title: "Generated Data", icon: "slider.horizontal.3")
                }

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
            }

            if appState.plotViewerState == nil && generatorViewModel.dataSummary == nil {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Load data to view histograms")
                )
            }
        }
        .padding(12)
    }
}

// MARK: - Data Series Plot Section

/// Sidebar section for selecting and plotting 1D data series from loaded NPZ files.
struct DataSeriesPlotSection: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let plotState = appState.plotViewerState {
                // Cascade stats shortcut
                if appState.rgViewerState?.info.hasCascadeStats == true {
                    Section {
                        Button {
                            plotState.renderCascadePlot()
                            appState.showingPlotView = true
                        } label: {
                            Label("mu vs Level", systemImage: "chart.line.uptrend.xyaxis")
                        }
                        .buttonStyle(.link)
                    } header: {
                        SectionHeader(title: "Cascade", icon: "waveform.path.ecg")
                    }
                }

                // Series picker
                Section {
                    ForEach(plotState.info.dataSeriesNames, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { plotState.selectedSeriesNames.contains(name) },
                            set: { _ in plotState.toggleSeries(name) }
                        )) {
                            Text(name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    HStack {
                        SectionHeader(title: "Data Series", icon: "chart.xyaxis.line")
                        Spacer()
                        Button("All") { plotState.selectAll() }
                            .font(.caption2)
                            .buttonStyle(.link)
                        Text("/")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("None") { plotState.selectNone() }
                            .font(.caption2)
                            .buttonStyle(.link)
                    }
                }

                // Plot button
                HStack {
                    Button {
                        plotState.renderPlot()
                        appState.showingPlotView = true
                    } label: {
                        Label("Plot Selected", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(plotState.selectedSeriesNames.isEmpty)

                    if appState.showingPlotView {
                        Button {
                            appState.showingPlotView = false
                        } label: {
                            Label("Show Slice", systemImage: "square.grid.3x3")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Data Series",
                    systemImage: "chart.line.downtrend.xyaxis",
                    description: Text("Load an .npz file with 1D data series to plot")
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
