import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imprint.app", category: "latexProject")

/// Manages multi-file LaTeX projects: dependency scanning, file watching,
/// and resolving \input{}/\include{}/\bibliography{} references.
actor LaTeXProjectService {
    static let shared = LaTeXProjectService()

    /// Root directory of the LaTeX project.
    private(set) var rootDirectory: URL?

    /// The main .tex file (the one being compiled).
    private(set) var mainFile: URL?

    /// All files included via \input{} / \include{}.
    private(set) var includedFiles: [URL] = []

    /// Bibliography files referenced via \bibliography{} / \addbibresource{}.
    private(set) var bibliographyFiles: [URL] = []

    /// Dependency graph: file → files it depends on.
    private(set) var dependencyGraph: [URL: [URL]] = [:]

    /// All labels found across project files.
    private(set) var labels: [String] = []

    /// All citation keys from .bib files.
    private(set) var citationKeys: [String] = []

    /// Callback when a watched file changes — triggers recompilation.
    var onFileChanged: ((URL) -> Void)?

    private var watchSources: [DispatchSourceFileSystemObject] = []

    // MARK: - Scanning

    /// Scan dependencies starting from the main .tex file.
    func scanDependencies(from mainTeX: URL) async {
        mainFile = mainTeX
        rootDirectory = mainTeX.deletingLastPathComponent()

        includedFiles = []
        bibliographyFiles = []
        dependencyGraph = [:]
        labels = []
        citationKeys = []

        scanFile(mainTeX, visited: &scanVisited)

        logger.info("Scanned project: \(self.includedFiles.count) included files, \(self.bibliographyFiles.count) bib files, \(self.labels.count) labels, \(self.citationKeys.count) cite keys")
    }

    private var scanVisited: [URL] = []

    private func scanFile(_ url: URL, visited: inout [URL]) {
        guard !visited.contains(url) else { return }
        visited.append(url)

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let dir = url.deletingLastPathComponent()
        var deps: [URL] = []

        // Parse \input{file} and \include{file}
        let inputPattern = #"\\(?:input|include)\{([^}]+)\}"#
        if let regex = try? NSRegularExpression(pattern: inputPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    var filename = String(content[range])
                    if !filename.hasSuffix(".tex") {
                        filename += ".tex"
                    }
                    let resolved = dir.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: resolved.path) {
                        includedFiles.append(resolved)
                        deps.append(resolved)
                    }
                }
            }
        }

        // Parse \bibliography{refs} and \addbibresource{refs.bib}
        let bibPattern = #"\\(?:bibliography|addbibresource)\{([^}]+)\}"#
        if let regex = try? NSRegularExpression(pattern: bibPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    let names = String(content[range]).components(separatedBy: ",")
                    for name in names {
                        var filename = name.trimmingCharacters(in: .whitespaces)
                        if !filename.hasSuffix(".bib") {
                            filename += ".bib"
                        }
                        let resolved = dir.appendingPathComponent(filename)
                        if FileManager.default.fileExists(atPath: resolved.path) {
                            bibliographyFiles.append(resolved)
                        }
                    }
                }
            }
        }

        // Parse \label{name}
        let labelPattern = #"\\label\{([^}]+)\}"#
        if let regex = try? NSRegularExpression(pattern: labelPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    labels.append(String(content[range]))
                }
            }
        }

        dependencyGraph[url] = deps

        // Recursively scan included files
        for dep in deps {
            scanFile(dep, visited: &visited)
        }

        // Parse .bib files for citation keys
        for bibURL in bibliographyFiles {
            if let bibContent = try? String(contentsOf: bibURL, encoding: .utf8) {
                parseBibKeys(bibContent)
            }
        }
    }

    private func parseBibKeys(_ content: String) {
        let pattern = #"@\w+\{([^,\s]+),"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                let key = String(content[range])
                if !citationKeys.contains(key) {
                    citationKeys.append(key)
                }
            }
        }
    }

    // MARK: - File Watching

    /// Start watching all project files for changes.
    func startWatching() {
        stopWatching()

        guard let root = rootDirectory else { return }

        var filesToWatch: [URL] = []
        if let main = mainFile { filesToWatch.append(main) }
        filesToWatch.append(contentsOf: includedFiles)
        filesToWatch.append(contentsOf: bibliographyFiles)

        for fileURL in filesToWatch {
            let fd = open(fileURL.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename],
                queue: .global()
            )

            let capturedURL = fileURL
            let capturedCallback = onFileChanged
            source.setEventHandler {
                capturedCallback?(capturedURL)
            }

            source.setCancelHandler {
                close(fd)
            }

            source.resume()
            watchSources.append(source)
        }

        logger.info("Watching \(filesToWatch.count) project files")
    }

    /// Stop watching all project files.
    func stopWatching() {
        for source in watchSources {
            source.cancel()
        }
        watchSources.removeAll()
    }

    // MARK: - Queries

    /// All project files (main + included + bib), for display in sidebar.
    var allProjectFiles: [URL] {
        var files: [URL] = []
        if let main = mainFile { files.append(main) }
        files.append(contentsOf: includedFiles)
        files.append(contentsOf: bibliographyFiles)
        return files
    }
}
