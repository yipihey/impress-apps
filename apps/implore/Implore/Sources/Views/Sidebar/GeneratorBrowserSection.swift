import SwiftUI
import ImploreCore

/// Browser section for exploring and using data generators
struct GeneratorBrowserSection: View {
    @Environment(GeneratorViewModel.self) var viewModel
    @State private var searchQuery = ""
    @State private var selectedCategory: GeneratorCategory?
    @State private var showingParameters = false

    var body: some View {
        VStack(spacing: 0) {
            // Search
            TextField("Search generators...", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Content
            List(selection: Binding(
                get: { viewModel.manager.selectedGenerator?.id },
                set: { id in
                    if let id = id {
                        viewModel.selectGenerator(id)
                        showingParameters = true
                    }
                }
            )) {
                // Categories
                ForEach(viewModel.manager.categories, id: \.self) { category in
                    Section(header: CategoryHeader(category: category)) {
                        ForEach(filteredGenerators(in: category), id: \.id) { generator in
                            GeneratorRow(generator: generator)
                                .tag(generator.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Generator parameters and generate button
            if let generator = viewModel.manager.selectedGenerator {
                VStack(spacing: 8) {
                    // Generator info
                    HStack {
                        Image(systemName: generator.icon)
                            .foregroundStyle(.blue)
                        Text(generator.name)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.horizontal, 12)

                    // Parameter form toggle
                    DisclosureGroup("Parameters", isExpanded: $showingParameters) {
                        ParameterFormView(
                            specs: viewModel.formState.specs,
                            formState: viewModel.formState
                        )
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 12)

                    // Generate button
                    HStack {
                        Button("Reset") {
                            viewModel.resetParameters()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button(action: {
                            Task {
                                await viewModel.generate()
                            }
                        }) {
                            if viewModel.isGenerating {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Text("Generate")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isGenerating || viewModel.formState.hasErrors)
                    }
                    .padding(.horizontal, 12)

                    // Error message
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .onChange(of: viewModel.manager.selectedGenerator?.id) { _, _ in
            viewModel.syncFormStateIfNeeded()
        }
        .accessibilityIdentifier("sidebar.generatorSection")
    }

    private func filteredGenerators(in category: GeneratorCategory) -> [GeneratorMetadata] {
        let generators = viewModel.manager.generators(in: category)

        if searchQuery.isEmpty {
            return generators
        }

        let query = searchQuery.lowercased()
        return generators.filter { generator in
            generator.name.lowercased().contains(query) ||
            generator.description.lowercased().contains(query) ||
            generator.id.lowercased().contains(query)
        }
    }
}

/// Category header with icon
struct CategoryHeader: View {
    let category: GeneratorCategory

    var body: some View {
        HStack {
            Image(systemName: categoryIcon)
                .foregroundStyle(.secondary)
            Text(categoryName)
        }
    }

    private var categoryName: String {
        switch category {
        case .noise: return "Noise"
        case .fractal: return "Fractals"
        case .statistical: return "Statistical"
        case .function: return "Functions"
        case .simulation: return "Simulations"
        }
    }

    private var categoryIcon: String {
        switch category {
        case .noise: return "waveform"
        case .fractal: return "sparkles"
        case .statistical: return "chart.bar"
        case .function: return "function"
        case .simulation: return "atom"
        }
    }
}

/// Row for a single generator
struct GeneratorRow: View {
    let generator: GeneratorMetadata

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: generator.icon)
                .frame(width: 24)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(generator.name)
                    .lineLimit(1)

                Text(generator.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Output dimension indicator
            Text("\(generator.outputDimensions)D")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            // Animation indicator
            if generator.supportsAnimation {
                Image(systemName: "play.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("sidebar.generatorRow.\(generator.id)")
    }
}

#Preview {
    GeneratorBrowserSection()
        .environment(GeneratorViewModel())
        .frame(width: 280, height: 600)
}
