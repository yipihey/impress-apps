# reMarkable Integration: Detailed Implementation Plan

## Overview

This plan breaks down the reMarkable integration into parallel workstreams. The critical path is **~6 weeks**, but with parallelization the calendar time can be reduced to **~4 weeks** with 2 developers or **~3 weeks** with focused effort on independent tracks.

---

## Dependency Graph

```
                                    ┌─────────────────────┐
                                    │   Core Data Model   │
                                    │   (Week 1, Days 1-2)│
                                    └──────────┬──────────┘
                                               │
                    ┌──────────────────────────┼──────────────────────────┐
                    │                          │                          │
                    ▼                          ▼                          ▼
        ┌───────────────────┐      ┌───────────────────┐      ┌───────────────────┐
        │  Settings Store   │      │   API Protocol    │      │  .rm File Parser  │
        │  (Week 1, Day 2)  │      │  (Week 1, Day 2)  │      │  (Week 1-2)       │
        └─────────┬─────────┘      └─────────┬─────────┘      └─────────┬─────────┘
                  │                          │                          │
                  │         ┌────────────────┼────────────────┐         │
                  │         │                │                │         │
                  │         ▼                ▼                ▼         │
                  │   ┌───────────┐   ┌───────────┐   ┌───────────┐     │
                  │   │Cloud API  │   │Local Sync │   │Dropbox    │     │
                  │   │(Week 1-2) │   │(Week 3)   │   │(Week 3)   │     │
                  │   └─────┬─────┘   └─────┬─────┘   └─────┬─────┘     │
                  │         │               │               │           │
                  │         └───────────────┼───────────────┘           │
                  │                         │                           │
                  ▼                         ▼                           ▼
        ┌───────────────────┐      ┌───────────────────┐      ┌───────────────────┐
        │   Settings UI     │      │  Sync Manager     │      │ Stroke Renderer   │
        │   (Week 2)        │      │  (Week 2-3)       │      │ (Week 2)          │
        └─────────┬─────────┘      └─────────┬─────────┘      └─────────┬─────────┘
                  │                          │                          │
                  │                          │                          ▼
                  │                          │                ┌───────────────────┐
                  │                          │                │ Annotation Import │
                  │                          │                │ (Week 2-3)        │
                  │                          │                └─────────┬─────────┘
                  │                          │                          │
                  └──────────────────────────┼──────────────────────────┘
                                             │
                                             ▼
                                   ┌───────────────────┐
                                   │  Detail View UI   │
                                   │  (Week 3)         │
                                   └─────────┬─────────┘
                                             │
                              ┌──────────────┼──────────────┐
                              │              │              │
                              ▼              ▼              ▼
                    ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
                    │ Background  │  │  Conflict   │  │   imprint   │
                    │ Scheduler   │  │ Resolution  │  │ Integration │
                    │ (Week 4)    │  │ (Week 4)    │  │ (Week 4)    │
                    └─────────────┘  └─────────────┘  └─────────────┘
```

---

## Workstream Breakdown

### Workstream A: Core Infrastructure (Critical Path)
### Workstream B: Format Parsing (Can Start Day 1)
### Workstream C: UI Components (Starts Week 2)
### Workstream D: Alternative Backends (Starts Week 3)

---

## Week-by-Week Plan

### Week 1: Foundation

#### Day 1-2: Core Data Model (Workstream A)

**Task A1: Create Core Data Entities**
```
Files to create:
- PublicationManagerCore/Sources/.../Persistence/RemarkableEntities.swift
- PublicationManagerCore/Sources/.../Persistence/PersistenceController+Remarkable.swift
```

```swift
// A1.1: CDRemarkableDocument entity
@objc(CDRemarkableDocument)
public class CDRemarkableDocument: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var remarkableID: String
    @NSManaged public var parentFolderID: String?
    @NSManaged public var version: Int32
    @NSManaged public var lastModifiedOnDevice: Date?
    @NSManaged public var lastSyncedAt: Date?
    @NSManaged public var syncState: String  // pending, synced, conflict, error
    @NSManaged public var deviceID: String?
    @NSManaged public var folderPath: String?  // Cached path for display

    // Relationships
    @NSManaged public var publication: CDPublication?
    @NSManaged public var linkedFile: CDLinkedFile?
    @NSManaged public var annotations: Set<CDRemarkableAnnotation>?
}

// A1.2: CDRemarkableAnnotation entity
@objc(CDRemarkableAnnotation)
public class CDRemarkableAnnotation: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var pageNumber: Int32
    @NSManaged public var layerName: String?
    @NSManaged public var annotationType: String  // highlight, ink, text
    @NSManaged public var strokesData: Data?
    @NSManaged public var renderedImage: Data?
    @NSManaged public var extractedText: String?
    @NSManaged public var boundsJSON: String
    @NSManaged public var color: String?
    @NSManaged public var dateCreated: Date
    @NSManaged public var dateModified: Date

    // Relationships
    @NSManaged public var document: CDRemarkableDocument?
    @NSManaged public var convertedAnnotation: CDAnnotation?
}

// A1.3: Add to PersistenceController entity creation
func createRemarkableEntities() -> [NSEntityDescription] { ... }
```

**Estimated time:** 4 hours
**Blocked by:** Nothing
**Blocks:** Everything else

---

#### Day 2: Settings Store & API Protocol (Workstream A, parallel start)

**Task A2: Settings Store**
```
File: PublicationManagerCore/Sources/.../ReMarkable/RemarkableSettingsStore.swift
```

```swift
@MainActor @Observable
public final class RemarkableSettingsStore {
    public static let shared = RemarkableSettingsStore()

    // Connection
    @AppStorage("remarkable.activeBackendID") public var activeBackendID: String = "cloud"
    @AppStorage("remarkable.isAuthenticated") public var isAuthenticated: Bool = false
    @AppStorage("remarkable.deviceName") public var deviceName: String?
    @AppStorage("remarkable.deviceID") public var deviceID: String?

    // Local folder backend
    @AppStorage("remarkable.localFolderPath") public var localFolderPath: String?
    public var localFolderBookmark: Data? // Security-scoped bookmark

    // Sync options
    @AppStorage("remarkable.autoSyncEnabled") public var autoSyncEnabled: Bool = true
    @AppStorage("remarkable.syncInterval") public var syncInterval: TimeInterval = 3600
    @AppStorage("remarkable.conflictResolution") public var conflictResolutionRaw: String = "ask"

    public var conflictResolution: ConflictResolution {
        get { ConflictResolution(rawValue: conflictResolutionRaw) ?? .ask }
        set { conflictResolutionRaw = newValue.rawValue }
    }

    // Organization
    @AppStorage("remarkable.createFoldersByCollection") public var createFoldersByCollection: Bool = true
    @AppStorage("remarkable.useReadingQueueFolder") public var useReadingQueueFolder: Bool = true
    @AppStorage("remarkable.rootFolderName") public var rootFolderName: String = "imbib"

    // Annotations
    @AppStorage("remarkable.importHighlights") public var importHighlights: Bool = true
    @AppStorage("remarkable.importInkNotes") public var importInkNotes: Bool = true
    @AppStorage("remarkable.enableOCR") public var enableOCR: Bool = true

    // Credential management (via Keychain)
    public func storeToken(_ token: String) throws { ... }
    public func retrieveToken() throws -> String? { ... }
    public func clearCredentials() { ... }
}

public enum ConflictResolution: String, Codable {
    case preferRemarkable, preferLocal, keepBoth, ask
}
```

**Estimated time:** 2 hours
**Blocked by:** Nothing (can start parallel with A1)
**Blocks:** Settings UI, API Client

---

**Task A3: Backend Protocol Definition**
```
File: PublicationManagerCore/Sources/.../ReMarkable/RemarkableSyncBackend.swift
```

```swift
// A3.1: Core protocol
public protocol RemarkableSyncBackend: Actor {
    var backendID: String { get }
    var displayName: String { get }

    func isAvailable() async -> Bool
    func authenticate() async throws
    func listDocuments() async throws -> [RemarkableDocumentInfo]
    func listFolders() async throws -> [RemarkableFolderInfo]
    func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String
    func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation]
    func downloadDocument(documentID: String) async throws -> RemarkableDocumentBundle
    func createFolder(name: String, parent: String?) async throws -> String
    func deleteDocument(documentID: String) async throws
    func getDeviceInfo() async throws -> RemarkableDeviceInfo
}

// A3.2: Data transfer objects
public struct RemarkableDocumentInfo: Codable, Identifiable {
    public let id: String
    public let name: String
    public let parentID: String?
    public let version: Int
    public let modifiedAt: Date
    public let type: DocumentType  // document, folder

    public enum DocumentType: String, Codable {
        case document = "DocumentType"
        case folder = "CollectionType"
    }
}

public struct RemarkableFolderInfo: Codable, Identifiable {
    public let id: String
    public let name: String
    public let parentID: String?
}

public struct RemarkableRawAnnotation: Codable {
    public let pageNumber: Int
    public let layerName: String?
    public let type: AnnotationType
    public let strokeData: Data?
    public let bounds: CGRect
    public let color: String?

    public enum AnnotationType: String, Codable {
        case highlight, ink, text
    }
}

public struct RemarkableDocumentBundle {
    public let documentInfo: RemarkableDocumentInfo
    public let pdfData: Data
    public let annotations: [RemarkableRawAnnotation]
    public let metadata: [String: Any]
}

public struct RemarkableDeviceInfo: Codable {
    public let deviceID: String
    public let deviceName: String
    public let storageUsed: Int64?
    public let storageTotal: Int64?
}
```

**Estimated time:** 2 hours
**Blocked by:** Nothing
**Blocks:** All backend implementations

---

#### Day 2-5: Cloud API Client (Workstream A)

**Task A4: API Client Implementation**
```
Files:
- PublicationManagerCore/Sources/.../ReMarkable/API/RemarkableAPIClient.swift
- PublicationManagerCore/Sources/.../ReMarkable/API/RemarkableAuthManager.swift
- PublicationManagerCore/Sources/.../ReMarkable/API/RemarkableAPIModels.swift
```

```swift
// A4.1: Auth Manager (device code flow)
public actor RemarkableAuthManager {
    private let baseURL = URL(string: "https://webapp-prod.cloud.remarkable.engineering")!

    public struct DeviceCodeResponse: Codable {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int
    }

    public func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("token/json/2/device/new"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["code": "", "deviceDesc": "desktop-macos", "deviceID": UUID().uuidString]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    public func pollForToken(deviceCode: String, interval: Int) async throws -> String {
        // Poll until user completes auth or timeout
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(interval))

            if let token = try await checkToken(deviceCode: deviceCode) {
                return token
            }
        }
        throw RemarkableError.authTimeout
    }

    private func checkToken(deviceCode: String) async throws -> String? {
        // POST to token endpoint, return token if ready
    }
}

// A4.2: API Client
public actor RemarkableAPIClient {
    private let storageURL = URL(string: "https://document-storage-production-dot-remarkable-production.appspot.com")!
    private var token: String?

    public func setToken(_ token: String) {
        self.token = token
    }

    public func listDocuments() async throws -> [RemarkableDocumentInfo] {
        guard let token else { throw RemarkableError.notAuthenticated }

        var request = URLRequest(url: storageURL.appendingPathComponent("document-storage/json/2/docs"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([RemarkableDocumentInfo].self, from: data)
    }

    public func uploadDocument(_ pdfData: Data, filename: String, parentID: String?) async throws -> String {
        // 1. Request upload URL
        // 2. Upload PDF via PUT
        // 3. Upload metadata
        // 4. Return document ID
    }

    public func downloadAnnotations(documentID: String) async throws -> Data {
        // Download .rm files from document's content
    }
}

// A4.3: Cloud Backend (implements protocol)
public actor RemarkableCloudBackend: RemarkableSyncBackend {
    public let backendID = "cloud"
    public let displayName = "reMarkable Cloud"

    private let apiClient = RemarkableAPIClient()
    private let authManager = RemarkableAuthManager()
    private let settings = RemarkableSettingsStore.shared

    public func isAvailable() async -> Bool {
        // Check network reachability
        true
    }

    public func authenticate() async throws {
        let codeResponse = try await authManager.requestDeviceCode()

        // Notify UI to show code to user
        await MainActor.run {
            NotificationCenter.default.post(
                name: .remarkableShowAuthCode,
                object: codeResponse
            )
        }

        let token = try await authManager.pollForToken(
            deviceCode: codeResponse.deviceCode,
            interval: codeResponse.interval
        )

        await apiClient.setToken(token)
        try settings.storeToken(token)

        // Fetch device info
        let deviceInfo = try await getDeviceInfo()
        await MainActor.run {
            settings.isAuthenticated = true
            settings.deviceName = deviceInfo.deviceName
            settings.deviceID = deviceInfo.deviceID
        }
    }

    // ... implement other protocol methods
}
```

**Estimated time:** 12 hours (2 days)
**Blocked by:** A3 (protocol)
**Blocks:** Push functionality, Sync manager

---

#### Day 1-5: .rm File Parser (Workstream B, PARALLEL)

**Task B1: .rm Binary Format Parser**
```
Files:
- PublicationManagerCore/Sources/.../ReMarkable/Format/RMFileParser.swift
- PublicationManagerCore/Sources/.../ReMarkable/Format/RMTypes.swift
```

```swift
// B1.1: Types
public struct RMFile {
    public let version: Int
    public let layers: [RMLayer]
}

public struct RMLayer {
    public let name: String
    public let strokes: [RMStroke]
}

public struct RMStroke {
    public let pen: PenType
    public let color: StrokeColor
    public let width: Float
    public let points: [RMPoint]

    public enum PenType: Int {
        case ballpoint = 2
        case marker = 3
        case fineliner = 4
        case highlighter = 5
        case eraser = 6
        case pencil = 7
        case mechanicalPencil = 13
        case brush = 12
    }

    public enum StrokeColor: Int {
        case black = 0
        case grey = 1
        case white = 2
        case yellow = 3
        case green = 4
        case pink = 5
        case blue = 6
        case red = 7
    }
}

public struct RMPoint {
    public let x: Float
    public let y: Float
    public let pressure: Float
    public let tiltX: Float
    public let tiltY: Float
}

// B1.2: Parser
public struct RMFileParser {

    public static func parse(_ data: Data) throws -> RMFile {
        var reader = BinaryReader(data: data)

        // Header: "reMarkable .lines file, version=X"
        let header = try reader.readString(until: 0x0A)
        guard header.hasPrefix("reMarkable .lines file") else {
            throw RMParseError.invalidHeader
        }

        let version = try parseVersion(from: header)

        // Number of layers
        let layerCount = try reader.readInt32()

        var layers: [RMLayer] = []
        for _ in 0..<layerCount {
            let layer = try parseLayer(&reader, version: version)
            layers.append(layer)
        }

        return RMFile(version: version, layers: layers)
    }

    private static func parseLayer(_ reader: inout BinaryReader, version: Int) throws -> RMLayer {
        let strokeCount = try reader.readInt32()
        var strokes: [RMStroke] = []

        for _ in 0..<strokeCount {
            let stroke = try parseStroke(&reader, version: version)
            strokes.append(stroke)
        }

        return RMLayer(name: "", strokes: strokes)
    }

    private static func parseStroke(_ reader: inout BinaryReader, version: Int) throws -> RMStroke {
        let pen = PenType(rawValue: Int(try reader.readInt32())) ?? .ballpoint
        let color = StrokeColor(rawValue: Int(try reader.readInt32())) ?? .black
        let _ = try reader.readInt32()  // Unknown
        let width = try reader.readFloat()
        let _ = try reader.readInt32()  // Unknown (v5+)
        let pointCount = try reader.readInt32()

        var points: [RMPoint] = []
        for _ in 0..<pointCount {
            let point = try parsePoint(&reader, version: version)
            points.append(point)
        }

        return RMStroke(pen: pen, color: color, width: width, points: points)
    }

    private static func parsePoint(_ reader: inout BinaryReader, version: Int) throws -> RMPoint {
        let x = try reader.readFloat()
        let y = try reader.readFloat()
        let pressure = try reader.readFloat()
        let tiltX = try reader.readFloat()
        let tiltY = try reader.readFloat()
        let _ = try reader.readFloat()  // Unknown (speed?)

        return RMPoint(x: x, y: y, pressure: pressure, tiltX: tiltX, tiltY: tiltY)
    }
}

// B1.3: Binary reader helper
struct BinaryReader {
    private var data: Data
    private var offset: Int = 0

    init(data: Data) { self.data = data }

    mutating func readInt32() throws -> Int32 {
        guard offset + 4 <= data.count else { throw RMParseError.unexpectedEOF }
        let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }
        offset += 4
        return Int32(littleEndian: value)
    }

    mutating func readFloat() throws -> Float {
        guard offset + 4 <= data.count else { throw RMParseError.unexpectedEOF }
        let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return Float(bitPattern: UInt32(littleEndian: value))
    }

    mutating func readString(until terminator: UInt8) throws -> String {
        var bytes: [UInt8] = []
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            if byte == terminator { break }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
```

**Estimated time:** 8 hours
**Blocked by:** Nothing (can start Day 1)
**Blocks:** Annotation import

---

### Week 2: Rendering & UI

#### Day 6-8: Stroke Renderer (Workstream B)

**Task B2: Core Graphics Stroke Renderer**
```
File: PublicationManagerCore/Sources/.../ReMarkable/Format/RMStrokeRenderer.swift
```

```swift
public struct RMStrokeRenderer {

    // reMarkable page dimensions (in device units)
    public static let pageWidth: CGFloat = 1404
    public static let pageHeight: CGFloat = 1872

    /// Render strokes to a CGImage at the specified scale.
    public static func render(
        _ rmFile: RMFile,
        scale: CGFloat = 2.0,
        backgroundColor: CGColor = .white
    ) -> CGImage? {
        let width = Int(pageWidth * scale)
        let height = Int(pageHeight * scale)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Fill background
        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Transform to match reMarkable coordinate system
        context.scaleBy(x: scale, y: scale)

        // Render each layer
        for layer in rmFile.layers {
            renderLayer(layer, in: context)
        }

        return context.makeImage()
    }

    /// Render a single layer.
    private static func renderLayer(_ layer: RMLayer, in context: CGContext) {
        for stroke in layer.strokes {
            renderStroke(stroke, in: context)
        }
    }

    /// Render a single stroke with pressure-sensitive width.
    private static func renderStroke(_ stroke: RMStroke, in context: CGContext) {
        guard stroke.points.count >= 2 else { return }

        context.setStrokeColor(color(for: stroke.color, pen: stroke.pen))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // For highlighter, use blend mode
        if stroke.pen == .highlighter {
            context.setBlendMode(.multiply)
            context.setAlpha(0.3)
        } else {
            context.setBlendMode(.normal)
            context.setAlpha(1.0)
        }

        // Draw stroke segments with varying width based on pressure
        for i in 1..<stroke.points.count {
            let p0 = stroke.points[i - 1]
            let p1 = stroke.points[i]

            let width = baseWidth(for: stroke.pen) * stroke.width * CGFloat(p1.pressure)
            context.setLineWidth(max(0.5, width))

            context.move(to: CGPoint(x: CGFloat(p0.x), y: CGFloat(p0.y)))
            context.addLine(to: CGPoint(x: CGFloat(p1.x), y: CGFloat(p1.y)))
            context.strokePath()
        }
    }

    private static func color(for strokeColor: RMStroke.StrokeColor, pen: RMStroke.PenType) -> CGColor {
        switch strokeColor {
        case .black: return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .grey: return CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        case .white: return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .yellow: return CGColor(red: 1, green: 0.95, blue: 0, alpha: 1)
        case .green: return CGColor(red: 0, green: 0.8, blue: 0.2, alpha: 1)
        case .pink: return CGColor(red: 1, green: 0.4, blue: 0.6, alpha: 1)
        case .blue: return CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 1)
        case .red: return CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
        }
    }

    private static func baseWidth(for pen: RMStroke.PenType) -> CGFloat {
        switch pen {
        case .ballpoint: return 1.5
        case .marker: return 3.0
        case .fineliner: return 1.0
        case .highlighter: return 15.0
        case .eraser: return 10.0
        case .pencil: return 2.0
        case .mechanicalPencil: return 1.0
        case .brush: return 4.0
        }
    }

    /// Render to PNG data.
    public static func renderToPNG(_ rmFile: RMFile, scale: CGFloat = 2.0) -> Data? {
        guard let image = render(rmFile, scale: scale) else { return nil }

        #if canImport(AppKit)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return nsImage.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
        #else
        return UIImage(cgImage: image).pngData()
        #endif
    }
}
```

**Estimated time:** 6 hours
**Blocked by:** B1 (.rm parser)
**Blocks:** Annotation import UI

---

#### Day 6-8: Settings UI (Workstream C, PARALLEL)

**Task C1: Settings View**
```
File: PublicationManagerCore/Sources/.../SharedViews/RemarkableSettingsView.swift
```

```swift
public struct RemarkableSettingsView: View {
    @State private var settings = RemarkableSettingsStore.shared
    @State private var isAuthenticating = false
    @State private var authCode: String?
    @State private var authError: String?
    @State private var showingFolderPicker = false

    public var body: some View {
        Form {
            connectionSection
            syncOptionsSection
            organizationSection
            annotationsSection
        }
        .formStyle(.grouped)
        .navigationTitle("reMarkable")
        .sheet(isPresented: $isAuthenticating) {
            AuthenticationSheet(
                code: authCode,
                error: authError,
                onCancel: { isAuthenticating = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .remarkableShowAuthCode)) { notification in
            if let response = notification.object as? RemarkableAuthManager.DeviceCodeResponse {
                authCode = response.userCode
                isAuthenticating = true
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            Picker("Sync Method", selection: $settings.activeBackendID) {
                Text("reMarkable Cloud").tag("cloud")
                Text("Local Folder").tag("local")
                Text("Dropbox").tag("dropbox")
            }

            switch settings.activeBackendID {
            case "cloud":
                cloudConnectionView
            case "local":
                localFolderView
            case "dropbox":
                dropboxView
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var cloudConnectionView: some View {
        if settings.isAuthenticated {
            LabeledContent("Device") {
                Text(settings.deviceName ?? "Unknown")
            }
            LabeledContent("Status") {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Button("Disconnect", role: .destructive) {
                Task { await disconnect() }
            }
        } else {
            Button("Connect to reMarkable Cloud") {
                Task { await authenticate() }
            }
        }
    }

    @ViewBuilder
    private var localFolderView: some View {
        HStack {
            Text(settings.localFolderPath ?? "Not selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Choose...") {
                showingFolderPicker = true
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                settings.localFolderPath = url.path
                // Store security-scoped bookmark
            }
        }
    }

    @ViewBuilder
    private var syncOptionsSection: some View {
        Section("Sync Options") {
            Toggle("Auto-sync annotations", isOn: $settings.autoSyncEnabled)

            if settings.autoSyncEnabled {
                Picker("Sync interval", selection: $settings.syncInterval) {
                    Text("Every 15 minutes").tag(TimeInterval(15 * 60))
                    Text("Every hour").tag(TimeInterval(3600))
                    Text("Every 6 hours").tag(TimeInterval(6 * 3600))
                    Text("Daily").tag(TimeInterval(24 * 3600))
                }
            }

            Picker("When annotations conflict", selection: $settings.conflictResolution) {
                Text("Prefer reMarkable").tag(ConflictResolution.preferRemarkable)
                Text("Prefer imbib").tag(ConflictResolution.preferLocal)
                Text("Keep both versions").tag(ConflictResolution.keepBoth)
                Text("Ask each time").tag(ConflictResolution.ask)
            }
        }
    }

    @ViewBuilder
    private var organizationSection: some View {
        Section("Folder Organization") {
            Toggle("Create folders from collections", isOn: $settings.createFoldersByCollection)
            Toggle("Use 'Reading Queue' folder", isOn: $settings.useReadingQueueFolder)
            TextField("Root folder name", text: $settings.rootFolderName)
        }
    }

    @ViewBuilder
    private var annotationsSection: some View {
        Section("Annotations") {
            Toggle("Import highlights", isOn: $settings.importHighlights)
            Toggle("Import handwritten notes", isOn: $settings.importInkNotes)

            if settings.importInkNotes {
                Toggle("OCR handwritten text", isOn: $settings.enableOCR)
            }
        }
    }

    private func authenticate() async {
        do {
            let backend = RemarkableCloudBackend()
            try await backend.authenticate()
        } catch {
            authError = error.localizedDescription
        }
    }

    private func disconnect() async {
        settings.clearCredentials()
        settings.isAuthenticated = false
        settings.deviceName = nil
    }
}

// Authentication sheet shown during device code flow
struct AuthenticationSheet: View {
    let code: String?
    let error: String?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tablet.landscape")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("Connect to reMarkable")
                .font(.title2)

            if let code {
                VStack(spacing: 8) {
                    Text("Enter this code at")
                        .foregroundStyle(.secondary)
                    Link("my.remarkable.com/device/desktop",
                         destination: URL(string: "https://my.remarkable.com/device/desktop")!)

                    Text(code)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .padding()
                        .background(.quaternary)
                        .clipShape(.rect(cornerRadius: 8))
                }

                ProgressView()
                    .padding(.top)

                Text("Waiting for confirmation...")
                    .foregroundStyle(.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(40)
        .frame(width: 400)
    }
}
```

**Estimated time:** 8 hours
**Blocked by:** A2 (settings store)
**Blocks:** Nothing (UI can be refined later)

---

#### Day 8-10: Annotation Import Pipeline (Workstream B)

**Task B3: Annotation Converter**
```
File: PublicationManagerCore/Sources/.../ReMarkable/RemarkableAnnotationConverter.swift
```

```swift
@MainActor
public final class RemarkableAnnotationConverter {

    private let persistence: AnnotationPersistence
    private let ocrEnabled: Bool

    public init(persistence: AnnotationPersistence = .shared) {
        self.persistence = persistence
        self.ocrEnabled = RemarkableSettingsStore.shared.enableOCR
    }

    /// Convert raw reMarkable annotations to imbib format.
    public func convert(
        document: CDRemarkableDocument,
        rmAnnotations: [RemarkableRawAnnotation],
        pdfDocument: PDFDocument,
        context: NSManagedObjectContext
    ) async throws -> [CDAnnotation] {
        var converted: [CDAnnotation] = []

        for rmAnnotation in rmAnnotations {
            // Create CDRemarkableAnnotation to store raw data
            let remarkableAnnotation = CDRemarkableAnnotation(context: context)
            remarkableAnnotation.id = UUID()
            remarkableAnnotation.pageNumber = Int32(rmAnnotation.pageNumber)
            remarkableAnnotation.annotationType = rmAnnotation.type.rawValue
            remarkableAnnotation.strokesData = rmAnnotation.strokeData
            remarkableAnnotation.boundsJSON = encodeBounds(rmAnnotation.bounds)
            remarkableAnnotation.color = rmAnnotation.color
            remarkableAnnotation.dateCreated = Date()
            remarkableAnnotation.dateModified = Date()
            remarkableAnnotation.document = document

            // Render and store image
            if let strokeData = rmAnnotation.strokeData,
               let rmFile = try? RMFileParser.parse(strokeData) {
                remarkableAnnotation.renderedImage = RMStrokeRenderer.renderToPNG(rmFile)
            }

            // Convert to standard CDAnnotation
            let cdAnnotation = try await convertToStandard(
                remarkableAnnotation: remarkableAnnotation,
                rmAnnotation: rmAnnotation,
                pdfDocument: pdfDocument,
                linkedFile: document.linkedFile,
                context: context
            )

            remarkableAnnotation.convertedAnnotation = cdAnnotation
            converted.append(cdAnnotation)
        }

        return converted
    }

    private func convertToStandard(
        remarkableAnnotation: CDRemarkableAnnotation,
        rmAnnotation: RemarkableRawAnnotation,
        pdfDocument: PDFDocument,
        linkedFile: CDLinkedFile?,
        context: NSManagedObjectContext
    ) async throws -> CDAnnotation {
        let cdAnnotation = CDAnnotation(context: context)
        cdAnnotation.id = UUID()
        cdAnnotation.pageNumber = Int32(rmAnnotation.pageNumber)
        cdAnnotation.boundsJSON = encodeBounds(rmAnnotation.bounds)
        cdAnnotation.dateCreated = Date()
        cdAnnotation.dateModified = Date()
        cdAnnotation.author = "reMarkable"
        cdAnnotation.linkedFile = linkedFile

        switch rmAnnotation.type {
        case .highlight:
            cdAnnotation.annotationType = "highlight"
            cdAnnotation.color = rmAnnotation.color ?? "#FFFF00"

            // Extract underlying text from PDF
            if let page = pdfDocument.page(at: rmAnnotation.pageNumber) {
                let selectedText = extractText(from: page, in: rmAnnotation.bounds)
                cdAnnotation.selectedText = selectedText
            }

        case .ink:
            cdAnnotation.annotationType = "ink"
            cdAnnotation.color = rmAnnotation.color ?? "#000000"

            // Store rendered image
            if let imageData = remarkableAnnotation.renderedImage {
                cdAnnotation.contents = imageData.base64EncodedString()
            }

            // OCR if enabled
            if ocrEnabled, let imageData = remarkableAnnotation.renderedImage {
                let ocrText = try await performOCR(imageData)
                remarkableAnnotation.extractedText = ocrText
                cdAnnotation.selectedText = ocrText
            }

        case .text:
            cdAnnotation.annotationType = "note"
            cdAnnotation.contents = remarkableAnnotation.extractedText ?? ""
        }

        return cdAnnotation
    }

    private func extractText(from page: PDFPage, in bounds: CGRect) -> String? {
        // Convert reMarkable coords to PDF coords
        let pdfBounds = convertBounds(bounds, toPage: page)
        let selection = page.selection(for: pdfBounds)
        return selection?.string
    }

    private func convertBounds(_ rmBounds: CGRect, toPage page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        let scaleX = pageBounds.width / RMStrokeRenderer.pageWidth
        let scaleY = pageBounds.height / RMStrokeRenderer.pageHeight

        return CGRect(
            x: rmBounds.origin.x * scaleX,
            y: pageBounds.height - (rmBounds.origin.y + rmBounds.height) * scaleY,
            width: rmBounds.width * scaleX,
            height: rmBounds.height * scaleY
        )
    }

    #if canImport(Vision)
    private func performOCR(_ imageData: Data) async throws -> String? {
        guard let cgImage = CGImage.from(pngData: imageData) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])

        guard let observations = request.results else { return nil }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }
    #else
    private func performOCR(_ imageData: Data) async throws -> String? { nil }
    #endif

    private func encodeBounds(_ rect: CGRect) -> String {
        let dict = ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
        let data = try? JSONEncoder().encode(dict)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
```

**Estimated time:** 8 hours
**Blocked by:** B1, B2
**Blocks:** Detail view annotation display

---

### Week 3: Sync & Integration

#### Day 11-13: Sync Manager (Workstream A)

**Task A5: Sync Manager**
```
File: PublicationManagerCore/Sources/.../ReMarkable/Sync/RemarkableSyncManager.swift
```

```swift
@MainActor @Observable
public final class RemarkableSyncManager {
    public static let shared = RemarkableSyncManager()

    // State
    public private(set) var isSyncing = false
    public private(set) var lastSyncDate: Date?
    public private(set) var pendingUploads: Int = 0
    public private(set) var pendingDownloads: Int = 0
    public private(set) var syncErrors: [SyncError] = []

    private let settings = RemarkableSettingsStore.shared
    private let converter = RemarkableAnnotationConverter()
    private let persistenceController: PersistenceController

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Push Operations

    /// Push a publication's PDF to reMarkable.
    public func pushToDevice(_ publication: CDPublication) async throws {
        guard let backend = await RemarkableBackendManager.shared.activeBackend else {
            throw RemarkableError.noBackendConfigured
        }

        guard let linkedFile = publication.linkedFiles?.first(where: { $0.isPDF }),
              let pdfURL = AttachmentManager.shared.resolveURL(for: linkedFile, in: publication.libraries?.first),
              let pdfData = try? Data(contentsOf: pdfURL)
        else {
            throw RemarkableError.noPDFAvailable
        }

        isSyncing = true
        defer { isSyncing = false }

        // Determine folder
        let folderID = try await resolveOrCreateFolder(for: publication, backend: backend)

        // Upload
        let filename = linkedFile.filename
        let documentID = try await backend.uploadDocument(pdfData, filename: filename, parentFolder: folderID)

        // Create tracking record
        let context = persistenceController.viewContext
        let rmDocument = CDRemarkableDocument(context: context)
        rmDocument.id = UUID()
        rmDocument.remarkableID = documentID
        rmDocument.parentFolderID = folderID
        rmDocument.version = 1
        rmDocument.lastSyncedAt = Date()
        rmDocument.syncState = "synced"
        rmDocument.publication = publication
        rmDocument.linkedFile = linkedFile

        try context.save()

        Logger.remarkable.info("Pushed \(filename) to reMarkable (ID: \(documentID))")
    }

    /// Push multiple publications.
    public func pushToDevice(_ publications: [CDPublication], progress: ((Int, Int) -> Void)? = nil) async throws {
        for (index, publication) in publications.enumerated() {
            progress?(index, publications.count)
            try await pushToDevice(publication)
        }
        progress?(publications.count, publications.count)
    }

    // MARK: - Pull Operations

    /// Pull annotations for a tracked document.
    public func pullAnnotations(for rmDocument: CDRemarkableDocument) async throws {
        guard let backend = await RemarkableBackendManager.shared.activeBackend else {
            throw RemarkableError.noBackendConfigured
        }

        guard let linkedFile = rmDocument.linkedFile,
              let pdfURL = AttachmentManager.shared.resolveURL(for: linkedFile, in: rmDocument.publication?.libraries?.first),
              let pdfDocument = PDFDocument(url: pdfURL)
        else {
            throw RemarkableError.noPDFAvailable
        }

        isSyncing = true
        defer { isSyncing = false }

        // Download annotations
        let rawAnnotations = try await backend.downloadAnnotations(documentID: rmDocument.remarkableID)

        // Convert and save
        let context = persistenceController.viewContext
        let converted = try await converter.convert(
            document: rmDocument,
            rmAnnotations: rawAnnotations,
            pdfDocument: pdfDocument,
            context: context
        )

        rmDocument.lastSyncedAt = Date()
        rmDocument.syncState = "synced"

        try context.save()

        Logger.remarkable.info("Pulled \(converted.count) annotations for \(rmDocument.remarkableID)")
    }

    /// Sync all tracked documents.
    public func syncAll() async throws {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
        let documents = try context.fetch(request)

        for document in documents {
            do {
                try await pullAnnotations(for: document)
            } catch {
                Logger.remarkable.error("Failed to sync \(document.remarkableID): \(error)")
                syncErrors.append(SyncError(documentID: document.remarkableID, error: error))
            }
        }

        lastSyncDate = Date()
    }

    // MARK: - Folder Management

    private var folderCache: [String: String] = [:]  // collection name -> folder ID

    private func resolveOrCreateFolder(
        for publication: CDPublication,
        backend: any RemarkableSyncBackend
    ) async throws -> String? {
        guard settings.createFoldersByCollection,
              let collection = publication.collections?.first
        else {
            return try await getOrCreateRootFolder(backend: backend)
        }

        let folderName = collection.name

        // Check cache
        if let cachedID = folderCache[folderName] {
            return cachedID
        }

        // Check device
        let folders = try await backend.listFolders()
        if let existing = folders.first(where: { $0.name == folderName }) {
            folderCache[folderName] = existing.id
            return existing.id
        }

        // Create new folder under root
        let rootID = try await getOrCreateRootFolder(backend: backend)
        let newID = try await backend.createFolder(name: folderName, parent: rootID)
        folderCache[folderName] = newID
        return newID
    }

    private func getOrCreateRootFolder(backend: any RemarkableSyncBackend) async throws -> String? {
        let rootName = settings.rootFolderName

        if let cachedID = folderCache[rootName] {
            return cachedID
        }

        let folders = try await backend.listFolders()
        if let existing = folders.first(where: { $0.name == rootName && $0.parentID == nil }) {
            folderCache[rootName] = existing.id
            return existing.id
        }

        let newID = try await backend.createFolder(name: rootName, parent: nil)
        folderCache[rootName] = newID
        return newID
    }

    // MARK: - Types

    public struct SyncError: Identifiable {
        public let id = UUID()
        public let documentID: String
        public let error: Error
        public var localizedDescription: String { error.localizedDescription }
    }
}
```

**Estimated time:** 10 hours
**Blocked by:** A4 (API client), B3 (converter)
**Blocks:** Background scheduler, UI integration

---

#### Day 11-13: Alternative Backends (Workstream D, PARALLEL)

**Task D1: Local Folder Backend**
```
File: PublicationManagerCore/Sources/.../ReMarkable/Local/RemarkableLocalBackend.swift
```

```swift
public actor RemarkableLocalBackend: RemarkableSyncBackend {
    public let backendID = "local"
    public let displayName = "Local Folder"

    private var folderURL: URL? {
        guard let path = RemarkableSettingsStore.shared.localFolderPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    public func isAvailable() async -> Bool {
        guard let url = folderURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func authenticate() async throws {
        // No auth needed for local folder
        guard await isAvailable() else {
            throw RemarkableError.localFolderNotAccessible
        }
    }

    public func listDocuments() async throws -> [RemarkableDocumentInfo] {
        guard let url = folderURL else { throw RemarkableError.localFolderNotConfigured }

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try contents.compactMap { fileURL -> RemarkableDocumentInfo? in
            // Look for .metadata files
            guard fileURL.pathExtension == "metadata" else { return nil }

            let data = try Data(contentsOf: fileURL)
            let metadata = try JSONDecoder().decode(LocalMetadata.self, from: data)

            let modDate = try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()

            return RemarkableDocumentInfo(
                id: fileURL.deletingPathExtension().lastPathComponent,
                name: metadata.visibleName,
                parentID: metadata.parent,
                version: metadata.version,
                modifiedAt: modDate,
                type: metadata.type == "CollectionType" ? .folder : .document
            )
        }
    }

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        guard let url = folderURL else { throw RemarkableError.localFolderNotConfigured }

        let documentID = UUID().uuidString
        let documentDir = url.appendingPathComponent(documentID)

        try FileManager.default.createDirectory(at: documentDir, withIntermediateDirectories: true)

        // Write PDF
        let pdfPath = documentDir.appendingPathComponent("\(documentID).pdf")
        try data.write(to: pdfPath)

        // Write metadata
        let metadata = LocalMetadata(
            visibleName: filename.replacingOccurrences(of: ".pdf", with: ""),
            parent: parentFolder,
            version: 1,
            type: "DocumentType"
        )
        let metadataPath = url.appendingPathComponent("\(documentID).metadata")
        try JSONEncoder().encode(metadata).write(to: metadataPath)

        // Write content file (required by reMarkable)
        let content = LocalContent(fileType: "pdf")
        let contentPath = url.appendingPathComponent("\(documentID).content")
        try JSONEncoder().encode(content).write(to: contentPath)

        return documentID
    }

    public func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation] {
        guard let url = folderURL else { throw RemarkableError.localFolderNotConfigured }

        let documentDir = url.appendingPathComponent(documentID)
        var annotations: [RemarkableRawAnnotation] = []

        // Find .rm files (one per page that has annotations)
        let contents = try FileManager.default.contentsOfDirectory(at: documentDir, includingPropertiesForKeys: nil)

        for fileURL in contents where fileURL.pathExtension == "rm" {
            let pageNumber = Int(fileURL.deletingPathExtension().lastPathComponent) ?? 0
            let data = try Data(contentsOf: fileURL)
            let rmFile = try RMFileParser.parse(data)

            // Convert strokes to annotations
            for layer in rmFile.layers {
                for stroke in layer.strokes {
                    let annotation = RemarkableRawAnnotation(
                        pageNumber: pageNumber,
                        layerName: layer.name,
                        type: stroke.pen == .highlighter ? .highlight : .ink,
                        strokeData: data,  // Store full layer for rendering
                        bounds: calculateBounds(stroke),
                        color: colorString(stroke.color)
                    )
                    annotations.append(annotation)
                }
            }
        }

        return annotations
    }

    // ... other protocol methods

    private struct LocalMetadata: Codable {
        let visibleName: String
        let parent: String?
        let version: Int
        let type: String
    }

    private struct LocalContent: Codable {
        let fileType: String
    }
}
```

**Estimated time:** 6 hours
**Blocked by:** A3 (protocol), B1 (parser)
**Blocks:** Nothing (alternative to cloud)

---

**Task D2: Dropbox Bridge Backend**
```
File: PublicationManagerCore/Sources/.../ReMarkable/Local/RemarkableDropboxBackend.swift
```

```swift
public actor RemarkableDropboxBackend: RemarkableSyncBackend {
    public let backendID = "dropbox"
    public let displayName = "Dropbox Integration"

    // reMarkable uses ~/Dropbox/Apps/reMarkable/ by default
    private var dropboxURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultPath = home.appendingPathComponent("Dropbox/Apps/reMarkable")

        if FileManager.default.fileExists(atPath: defaultPath.path) {
            return defaultPath
        }

        // Check alternate locations or user-configured path
        return nil
    }

    public func isAvailable() async -> Bool {
        dropboxURL != nil
    }

    public func authenticate() async throws {
        guard await isAvailable() else {
            throw RemarkableError.dropboxFolderNotFound
        }
    }

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        guard let url = dropboxURL else { throw RemarkableError.dropboxFolderNotFound }

        // For Dropbox, we just write PDF to the folder
        // reMarkable will sync it automatically
        let targetDir = parentFolder.map { url.appendingPathComponent($0) } ?? url
        let targetFile = targetDir.appendingPathComponent(filename)

        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try data.write(to: targetFile)

        // Return filename as "ID" since Dropbox doesn't use UUIDs
        return filename
    }

    public func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation] {
        // Dropbox integration is one-way (upload only)
        // Annotations don't sync back via Dropbox
        throw RemarkableError.annotationSyncNotSupported(backend: "dropbox")
    }

    // ... minimal implementations for other methods
}
```

**Estimated time:** 3 hours
**Blocked by:** A3 (protocol)
**Blocks:** Nothing

---

#### Day 11-15: Detail View Integration (Workstream C)

**Task C2: Publication Detail reMarkable Section**
```
File: PublicationManagerCore/Sources/.../SharedViews/RemarkableStatusSection.swift
```

```swift
public struct RemarkableStatusSection: View {
    let publication: CDPublication

    @State private var remarkableDocument: CDRemarkableDocument?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingAnnotations = false

    private let syncManager = RemarkableSyncManager.shared

    public var body: some View {
        Section("reMarkable") {
            if let doc = remarkableDocument {
                connectedView(doc)
            } else {
                disconnectedView
            }
        }
        .task {
            await loadRemarkableDocument()
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sheet(isPresented: $showingAnnotations) {
            if let doc = remarkableDocument {
                RemarkableAnnotationsSheet(document: doc)
            }
        }
    }

    @ViewBuilder
    private func connectedView(_ doc: CDRemarkableDocument) -> some View {
        LabeledContent("Status") {
            SyncStateBadge(state: doc.syncState)
        }

        if let lastSync = doc.lastSyncedAt {
            LabeledContent("Last synced") {
                Text(lastSync, style: .relative)
            }
        }

        if let annotations = doc.annotations, !annotations.isEmpty {
            Button {
                showingAnnotations = true
            } label: {
                LabeledContent("Annotations") {
                    HStack {
                        Text("\(annotations.count)")
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }

        HStack {
            Button("Sync Now") {
                Task { await syncAnnotations(doc) }
            }
            .disabled(isLoading)

            Spacer()

            Button("Remove", role: .destructive) {
                Task { await removeFromDevice(doc) }
            }
            .disabled(isLoading)
        }

        if isLoading {
            ProgressView()
        }
    }

    @ViewBuilder
    private var disconnectedView: some View {
        if publication.hasPDFDownloaded {
            Button {
                Task { await pushToDevice() }
            } label: {
                Label("Send to reMarkable", systemImage: "arrow.up.doc")
            }
            .disabled(isLoading || !RemarkableSettingsStore.shared.isAuthenticated)

            if !RemarkableSettingsStore.shared.isAuthenticated {
                Text("Connect to reMarkable in Settings first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Download PDF first to send to reMarkable")
                .foregroundStyle(.secondary)
        }

        if isLoading {
            ProgressView()
        }
    }

    private func loadRemarkableDocument() async {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
        request.predicate = NSPredicate(format: "publication == %@", publication)
        request.fetchLimit = 1

        remarkableDocument = try? context.fetch(request).first
    }

    private func pushToDevice() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await syncManager.pushToDevice(publication)
            await loadRemarkableDocument()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func syncAnnotations(_ doc: CDRemarkableDocument) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await syncManager.pullAnnotations(for: doc)
            await loadRemarkableDocument()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeFromDevice(_ doc: CDRemarkableDocument) async {
        isLoading = true
        defer { isLoading = false }

        do {
            guard let backend = await RemarkableBackendManager.shared.activeBackend else { return }
            try await backend.deleteDocument(documentID: doc.remarkableID)

            let context = PersistenceController.shared.viewContext
            context.delete(doc)
            try context.save()

            remarkableDocument = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SyncStateBadge: View {
    let state: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(displayText)
        }
        .font(.caption)
    }

    private var color: Color {
        switch state {
        case "synced": return .green
        case "pending": return .orange
        case "conflict": return .red
        case "error": return .red
        default: return .gray
        }
    }

    private var displayText: String {
        switch state {
        case "synced": return "Synced"
        case "pending": return "Pending"
        case "conflict": return "Conflict"
        case "error": return "Error"
        default: return "Unknown"
        }
    }
}
```

**Estimated time:** 6 hours
**Blocked by:** A5 (sync manager)
**Blocks:** Nothing

---

### Week 4: Polish & imprint Integration

#### Day 16-17: Background Scheduler (Workstream A)

**Task A6: Background Sync Scheduler**
```
File: PublicationManagerCore/Sources/.../ReMarkable/Sync/RemarkableSyncScheduler.swift
```

```swift
public actor RemarkableSyncScheduler {
    public static let shared = RemarkableSyncScheduler()

    private var isRunning = false
    private var task: Task<Void, Never>?
    private let settings = RemarkableSettingsStore.shared
    private let syncManager = RemarkableSyncManager.shared

    // Statistics
    public private(set) var totalSyncCycles: Int = 0
    public private(set) var totalAnnotationsSynced: Int = 0
    public private(set) var lastSuccessfulSync: Date?

    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        Logger.remarkable.info("Starting reMarkable sync scheduler")

        task = Task {
            while isRunning && !Task.isCancelled {
                await runSyncCycle()

                let interval = await MainActor.run { settings.syncInterval }
                guard interval > 0 else {
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }

                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        isRunning = false
        task?.cancel()
        task = nil
        Logger.remarkable.info("Stopped reMarkable sync scheduler")
    }

    public func triggerImmediateSync() async {
        await runSyncCycle()
    }

    private func runSyncCycle() async {
        guard await MainActor.run({ settings.autoSyncEnabled && settings.isAuthenticated }) else {
            return
        }

        Logger.remarkable.info("Running reMarkable sync cycle")
        totalSyncCycles += 1

        do {
            try await syncManager.syncAll()
            lastSuccessfulSync = Date()

            // Count synced annotations
            let annotationCount = await MainActor.run {
                syncManager.pendingDownloads  // Or actual count
            }
            totalAnnotationsSynced += annotationCount

        } catch {
            Logger.remarkable.error("Sync cycle failed: \(error)")
        }
    }
}

// Start scheduler when app launches (in App delegate or scene)
extension RemarkableSyncScheduler {
    public static func startIfConfigured() {
        Task {
            if RemarkableSettingsStore.shared.autoSyncEnabled &&
               RemarkableSettingsStore.shared.isAuthenticated {
                await shared.start()
            }
        }
    }
}
```

**Estimated time:** 4 hours
**Blocked by:** A5 (sync manager)
**Blocks:** Nothing

---

#### Day 16-18: Conflict Resolution (Workstream A)

**Task A7: Conflict Resolution UI**
```
File: PublicationManagerCore/Sources/.../SharedViews/RemarkableConflictView.swift
```

```swift
public struct RemarkableConflictView: View {
    let conflict: RemarkableConflict
    let onResolve: (ConflictResolution) -> Void

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Annotation Conflict")
                    .font(.headline)
            }

            // Description
            Text("The annotations for \"\(conflict.publicationTitle)\" have been modified both in imbib and on your reMarkable.")
                .multilineTextAlignment(.center)

            // Comparison
            HStack(alignment: .top, spacing: 20) {
                ConflictSide(
                    title: "imbib",
                    date: conflict.localModified,
                    count: conflict.localAnnotationCount,
                    preview: conflict.localPreview
                )

                Divider()

                ConflictSide(
                    title: "reMarkable",
                    date: conflict.remoteModified,
                    count: conflict.remoteAnnotationCount,
                    preview: conflict.remotePreview
                )
            }
            .frame(maxHeight: 300)

            // Resolution options
            VStack(spacing: 12) {
                Button {
                    onResolve(.preferLocal)
                } label: {
                    Label("Keep imbib annotations", systemImage: "arrow.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onResolve(.preferRemarkable)
                } label: {
                    Label("Keep reMarkable annotations", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onResolve(.keepBoth)
                } label: {
                    Label("Keep both (merge)", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500)
    }
}

struct ConflictSide: View {
    let title: String
    let date: Date
    let count: Int
    let preview: Image?

    var body: some View {
        VStack {
            Text(title)
                .font(.headline)

            if let preview {
                preview
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .border(.secondary.opacity(0.3))
            }

            Text("\(count) annotations")
                .foregroundStyle(.secondary)

            Text(date, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

public struct RemarkableConflict: Identifiable {
    public let id = UUID()
    public let documentID: String
    public let publicationTitle: String
    public let localModified: Date
    public let remoteModified: Date
    public let localAnnotationCount: Int
    public let remoteAnnotationCount: Int
    public let localPreview: Image?
    public let remotePreview: Image?
}
```

**Estimated time:** 6 hours
**Blocked by:** A5 (sync manager)
**Blocks:** Nothing

---

#### Day 18-20: imprint Integration (Workstream C)

**Task C3: Annotation Export for imprint**
```
File: PublicationManagerCore/Sources/.../ReMarkable/ImprintIntegration.swift
```

```swift
public struct RemarkableQuote: Codable, Identifiable {
    public let id: UUID
    public let text: String
    public let pageNumber: Int
    public let citeKey: String
    public let publicationTitle: String
    public let annotationType: String  // highlight, note, ink
    public let extractedAt: Date
    public let hasImage: Bool
    public let imageData: Data?
}

extension CDRemarkableAnnotation {
    /// Convert to quotable format for imprint.
    public func toQuote(publication: CDPublication) -> RemarkableQuote {
        RemarkableQuote(
            id: id,
            text: extractedText ?? convertedAnnotation?.selectedText ?? "",
            pageNumber: Int(pageNumber),
            citeKey: publication.citeKey,
            publicationTitle: publication.title ?? "Untitled",
            annotationType: annotationType,
            extractedAt: Date(),
            hasImage: renderedImage != nil,
            imageData: renderedImage
        )
    }
}

// URL scheme for imprint to request quotes
// imbib://remarkable/quotes?citeKey=smith2020&returnTo=pasteboard
extension URLSchemeHandler {
    func handleRemarkableQuotesRequest(citeKey: String) async {
        let context = PersistenceController.shared.viewContext

        // Find publication
        let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
        pubRequest.predicate = NSPredicate(format: "citeKey == %@", citeKey)

        guard let publication = try? context.fetch(pubRequest).first else { return }

        // Find reMarkable document
        let docRequest = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
        docRequest.predicate = NSPredicate(format: "publication == %@", publication)

        guard let rmDocument = try? context.fetch(docRequest).first,
              let annotations = rmDocument.annotations
        else { return }

        // Convert to quotes
        let quotes = annotations.map { $0.toQuote(publication: publication) }

        // Return via pasteboard
        if let data = try? JSONEncoder().encode(quotes) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType("com.imbib.remarkable-quotes"))
        }
    }
}
```

**Task C4: Annotation Timeline View (for imprint sidebar)**
```
File: PublicationManagerCore/Sources/.../SharedViews/AnnotationTimelineView.swift
```

```swift
public struct AnnotationTimelineView: View {
    let publication: CDPublication
    @State private var annotations: [TimelineAnnotation] = []

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(annotations) { annotation in
                    AnnotationTimelineRow(annotation: annotation)
                }
            }
            .padding()
        }
        .task {
            await loadAnnotations()
        }
    }

    private func loadAnnotations() async {
        // Combine CDAnnotation + CDRemarkableAnnotation
        var timeline: [TimelineAnnotation] = []

        // Local annotations
        if let linkedFiles = publication.linkedFiles {
            for file in linkedFiles where file.isPDF {
                if let cdAnnotations = file.annotations {
                    timeline += cdAnnotations.map { TimelineAnnotation(from: $0) }
                }
            }
        }

        // reMarkable annotations
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
        request.predicate = NSPredicate(format: "publication == %@", publication)

        if let rmDoc = try? context.fetch(request).first,
           let rmAnnotations = rmDoc.annotations {
            timeline += rmAnnotations.map { TimelineAnnotation(from: $0, publication: publication) }
        }

        // Sort by date
        annotations = timeline.sorted { $0.date > $1.date }
    }
}

struct TimelineAnnotation: Identifiable {
    let id: UUID
    let type: String
    let text: String
    let pageNumber: Int
    let date: Date
    let source: Source
    let imageData: Data?

    enum Source {
        case local, remarkable
    }

    init(from cdAnnotation: CDAnnotation) {
        id = cdAnnotation.id
        type = cdAnnotation.annotationType
        text = cdAnnotation.selectedText ?? cdAnnotation.contents ?? ""
        pageNumber = Int(cdAnnotation.pageNumber)
        date = cdAnnotation.dateCreated
        source = .local
        imageData = nil
    }

    init(from rmAnnotation: CDRemarkableAnnotation, publication: CDPublication) {
        id = rmAnnotation.id
        type = rmAnnotation.annotationType
        text = rmAnnotation.extractedText ?? ""
        pageNumber = Int(rmAnnotation.pageNumber)
        date = rmAnnotation.dateCreated
        source = .remarkable
        imageData = rmAnnotation.renderedImage
    }
}

struct AnnotationTimelineRow: View {
    let annotation: TimelineAnnotation
    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Source indicator
            Image(systemName: annotation.source == .remarkable ? "tablet.landscape" : "doc.text")
                .foregroundStyle(annotation.source == .remarkable ? .orange : .blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                // Type and page
                HStack {
                    Text(annotation.type.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text("Page \(annotation.pageNumber + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Content
                if !annotation.text.isEmpty {
                    Text(annotation.text)
                        .font(.callout)
                        .lineLimit(3)
                }

                if let imageData = annotation.imageData,
                   let image = NSImage(data: imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 100)
                        .clipShape(.rect(cornerRadius: 4))
                }

                // Actions
                HStack {
                    Button {
                        copyToClipboard()
                    } label: {
                        Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    Spacer()

                    Text(annotation.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(annotation.text, forType: .string)

        isCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            isCopied = false
        }
    }
}
```

**Estimated time:** 8 hours
**Blocked by:** B3 (annotation converter)
**Blocks:** Nothing

---

## Parallel Execution Summary

```
Week 1:
├── Workstream A: Core Data Model → Settings → Protocol → API Client
└── Workstream B: .rm Parser (PARALLEL from Day 1)

Week 2:
├── Workstream A: API Client (continued)
├── Workstream B: Renderer → Annotation Converter
└── Workstream C: Settings UI (PARALLEL)

Week 3:
├── Workstream A: Sync Manager
├── Workstream C: Detail View UI
└── Workstream D: Local Backend, Dropbox Backend (PARALLEL)

Week 4:
├── Workstream A: Background Scheduler, Conflict Resolution
└── Workstream C: imprint Integration (PARALLEL)
```

---

## Resource Allocation

### Option 1: Single Developer (6 weeks)
- Follow critical path: A → B → C → D
- ~160 hours total

### Option 2: Two Developers (4 weeks)
- Developer 1: Workstreams A + C (infrastructure + UI)
- Developer 2: Workstreams B + D (parsing + backends)
- ~80 hours each

### Option 3: Three Developers (3 weeks)
- Developer 1: Workstream A (critical path)
- Developer 2: Workstream B (parsing)
- Developer 3: Workstreams C + D (UI + backends)
- ~55 hours each

---

## Testing Strategy

### Unit Tests (per task)
- A1: Entity creation, relationships
- A4: API client mocking, auth flow
- B1: .rm parsing with test files
- B2: Renderer output comparison

### Integration Tests
- Push → Pull round-trip
- Conflict detection and resolution
- OCR accuracy (with sample images)

### Manual Testing
- Device code auth flow
- Multi-device sync
- Offline/online transitions

---

## Milestones

| Milestone | Target | Deliverable |
|-----------|--------|-------------|
| M1: Auth Working | End of Week 1 | Can authenticate with reMarkable Cloud |
| M2: Push Working | End of Week 2 | Can push PDFs to device |
| M3: Pull Working | End of Week 3 | Can pull and display annotations |
| M4: Full Sync | End of Week 4 | Bidirectional sync with conflict handling |
| M5: imprint Ready | End of Week 4 | Annotations usable for citations |
