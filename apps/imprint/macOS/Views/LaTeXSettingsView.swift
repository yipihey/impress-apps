import SwiftUI

/// Settings pane for LaTeX compilation configuration.
struct LaTeXSettingsView: View {
    @AppStorage("imprint.latex.defaultEngine") private var defaultEngine = "pdflatex"
    @AppStorage("imprint.latex.autoCompile") private var autoCompileEnabled = true
    @AppStorage("imprint.latex.compileDebounceMs") private var compileDebounceMs = 1500
    @AppStorage("imprint.latex.shellEscape") private var shellEscape = false
    @AppStorage("imprint.latex.showBoxWarnings") private var showBoxWarnings = false

    private let texManager = TeXDistributionManager.shared
    @State private var verificationResult: String?
    @State private var isVerifying = false

    var body: some View {
        Form {
            texDistributionSection
            engineSection
            compilationSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .padding()
        .task {
            texManager.discoverDistribution()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var texDistributionSection: some View {
        Section("TeX Distribution") {
            HStack {
                Text("Path")
                Spacer()
                if texManager.isAvailable {
                    Text(texManager.distributionDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not found")
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Text("Status")
                Spacer()
                if texManager.isAvailable {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("\(texManager.installedEngines.count) engine\(texManager.installedEngines.count == 1 ? "" : "s") available")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Install MacTeX or TeX Live")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Browse...") {
                    texManager.requestAccess()
                }
                .help("Select TeX distribution directory manually")

                Button("Verify Installation") {
                    isVerifying = true
                    Task {
                        verificationResult = await texManager.verifyInstallation()
                        isVerifying = false
                    }
                }
                .disabled(isVerifying || !texManager.isAvailable)
            }

            if let result = verificationResult {
                Text(result)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var engineSection: some View {
        Section("Default Engine") {
            Picker("Engine", selection: $defaultEngine) {
                ForEach(LaTeXEngine.allCases, id: \.rawValue) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .help("latexmk handles caching and multi-pass compilation automatically")

            if defaultEngine == "latexmk" {
                Text("latexmk automatically runs BibTeX/Biber and multiple passes as needed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var compilationSection: some View {
        Section("Compilation") {
            Toggle("Auto-compile on save", isOn: $autoCompileEnabled)
                .help("Automatically recompile when the document changes")

            if autoCompileEnabled {
                Stepper(
                    "Debounce delay: \(compileDebounceMs)ms",
                    value: $compileDebounceMs,
                    in: 500...5000,
                    step: 250
                )
                .help("Wait time after typing before starting compilation. LaTeX is heavier than Typst, so longer delays save CPU.")
            }

            Toggle("Enable shell escape", isOn: $shellEscape)
                .help("Required by some packages (minted, pythontex). Allows TeX to execute shell commands — enable only if needed.")
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Toggle("Show overfull/underfull box warnings", isOn: $showBoxWarnings)
                .help("Display informational messages about text that overflows or underflows its box")
        }
    }
}

#Preview {
    LaTeXSettingsView()
        .frame(width: 500, height: 500)
}
