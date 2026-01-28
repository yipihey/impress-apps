//
//  IOSDictationService.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-28.
//

import Foundation
import Speech
import AVFoundation
import Combine
import SwiftUI
import os.log

private let dictationLogger = Logger(subsystem: "com.imbib.app", category: "dictation")

// MARK: - iOS Dictation Service

/// Voice dictation service for imbib on iOS.
///
/// Features:
/// - Continuous speech recognition
/// - Auto-punctuation
/// - Voice commands for imbib-specific actions
/// - Waveform visualization support
@MainActor
public final class IOSDictationService: NSObject, ObservableObject {

    // MARK: - Published Properties

    /// Whether dictation is currently active
    @Published public private(set) var isRecording = false

    /// The current transcription text (live)
    @Published public private(set) var currentTranscription = ""

    /// Audio level for waveform visualization (0.0-1.0)
    @Published public private(set) var audioLevel: Float = 0

    /// Error message if dictation fails
    @Published public private(set) var errorMessage: String?

    /// Whether speech recognition is available
    @Published public private(set) var isAvailable = false

    // MARK: - Properties

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Callback when text should be inserted
    public var onTextRecognized: ((String) -> Void)?

    /// Callback for voice commands
    public var onVoiceCommand: ((VoiceCommand) -> Void)?

    // MARK: - Voice Commands

    public enum VoiceCommand: String, CaseIterable {
        // Text formatting
        case newParagraph = "new paragraph"
        case newLine = "new line"
        case bold = "bold"
        case italic = "italic"

        // Imbib-specific commands
        case newNote = "new note"
        case saveNote = "save note"
        case nextPaper = "next paper"
        case previousPaper = "previous paper"
        case searchPapers = "search papers"

        // Navigation
        case showPDF = "show pdf"
        case showNotes = "show notes"
        case showBibTeX = "show bibtex"

        // Control
        case undo = "undo"
        case stopDictation = "stop dictation"

        /// The text/markup to insert for this command (if any)
        public var insertText: String? {
            switch self {
            case .newParagraph: return "\n\n"
            case .newLine: return "\n"
            case .bold: return "**"  // Markdown bold marker
            case .italic: return "*"  // Markdown italic marker
            default: return nil
            }
        }

        /// Whether this command triggers a navigation action
        public var isNavigationCommand: Bool {
            switch self {
            case .nextPaper, .previousPaper, .showPDF, .showNotes, .showBibTeX, .searchPapers:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Initialization

    public override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        checkAvailability()
    }

    // MARK: - Availability

    private func checkAvailability() {
        guard let recognizer = speechRecognizer else {
            isAvailable = false
            return
        }

        isAvailable = recognizer.isAvailable
    }

    // MARK: - Authorization

    /// Requests authorization for speech recognition.
    public func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    switch status {
                    case .authorized:
                        self.isAvailable = true
                        dictationLogger.info("Speech recognition authorized")
                        continuation.resume(returning: true)
                    case .denied, .restricted, .notDetermined:
                        self.isAvailable = false
                        self.errorMessage = "Speech recognition not authorized"
                        dictationLogger.warning("Speech recognition not authorized: \(status.rawValue)")
                        continuation.resume(returning: false)
                    @unknown default:
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    // MARK: - Recording Control

    /// Starts dictation.
    public func startRecording() async throws {
        guard isAvailable else {
            throw DictationError.notAvailable
        }

        guard !isRecording else {
            return
        }

        // Request microphone permission
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            throw DictationError.requestFailed
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true // iOS 16+ auto-punctuation

        // Configure audio input
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            self?.updateAudioLevel(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Start recognition
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                self.processRecognitionResult(result)
            }

            if let error = error {
                dictationLogger.error("Recognition error: \(error.localizedDescription)")
                self.stopRecording()
            }
        }

        isRecording = true
        errorMessage = nil
        dictationLogger.info("Dictation started")
    }

    /// Stops dictation.
    public func stopRecording() {
        guard isRecording else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        isRecording = false
        audioLevel = 0
        currentTranscription = ""

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        dictationLogger.info("Dictation stopped")
    }

    /// Toggles dictation on/off.
    public func toggleRecording() async {
        if isRecording {
            stopRecording()
        } else {
            do {
                try await startRecording()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Result Processing

    private func processRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString
        currentTranscription = text

        // Check for voice commands
        if let command = detectVoiceCommand(in: text) {
            handleVoiceCommand(command)
            return
        }

        // If final, insert the text
        if result.isFinal {
            onTextRecognized?(text)
            currentTranscription = ""
        }
    }

    private func detectVoiceCommand(in text: String) -> VoiceCommand? {
        let lowercased = text.lowercased()

        for command in VoiceCommand.allCases {
            if lowercased.hasSuffix(command.rawValue) {
                return command
            }
        }

        return nil
    }

    private func handleVoiceCommand(_ command: VoiceCommand) {
        dictationLogger.info("Voice command detected: \(command.rawValue)")

        // Remove the command text from transcription
        let commandLength = command.rawValue.count
        if currentTranscription.count >= commandLength {
            let trimmedText = String(currentTranscription.dropLast(commandLength)).trimmingCharacters(in: .whitespaces)
            if !trimmedText.isEmpty {
                onTextRecognized?(trimmedText)
            }
        }

        // Handle the command
        switch command {
        case .stopDictation:
            stopRecording()
        case .undo:
            onVoiceCommand?(command)
        default:
            onVoiceCommand?(command)
            if let insertText = command.insertText {
                onTextRecognized?(insertText)
            }
        }

        currentTranscription = ""
    }

    // MARK: - Audio Level

    private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0

        for i in 0..<frameLength {
            sum += abs(channelData[i])
        }

        let average = sum / Float(frameLength)
        let normalizedLevel = min(1.0, average * 10)

        DispatchQueue.main.async {
            self.audioLevel = normalizedLevel
        }
    }
}

// MARK: - Errors

public enum DictationError: LocalizedError {
    case notAvailable
    case notAuthorized
    case requestFailed
    case audioSessionFailed

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Speech recognition is not available"
        case .notAuthorized:
            return "Speech recognition is not authorized"
        case .requestFailed:
            return "Failed to create speech recognition request"
        case .audioSessionFailed:
            return "Failed to configure audio session"
        }
    }
}

// MARK: - Dictation Overlay View

/// Visual overlay showing dictation status and waveform.
public struct IOSDictationOverlay: View {

    @ObservedObject var service: IOSDictationService

    public init(service: IOSDictationService) {
        self.service = service
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Waveform visualization
            WaveformView(level: service.audioLevel)
                .frame(height: 60)

            // Current transcription
            if !service.currentTranscription.isEmpty {
                Text(service.currentTranscription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(service.isRecording ? Color.red : Color.gray)
                    .frame(width: 12, height: 12)

                Text(service.isRecording ? "Listening..." : "Tap to dictate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Error message
            if let error = service.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let level: Float

    private let barCount = 20

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(level: barLevel(for: index))
            }
        }
    }

    private func barLevel(for index: Int) -> CGFloat {
        let center = barCount / 2
        let distance = abs(index - center)
        let falloff = 1.0 - (Double(distance) / Double(center))
        let noise = Double.random(in: 0.8...1.2)
        return CGFloat(level) * CGFloat(falloff * noise)
    }
}

struct WaveformBar: View {
    let level: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 4, height: max(4, level * 60))
            .animation(.easeInOut(duration: 0.1), value: level)
    }
}

// MARK: - Dictation Button

/// A floating button for triggering dictation.
public struct DictationButton: View {

    @ObservedObject var service: IOSDictationService

    public init(service: IOSDictationService) {
        self.service = service
    }

    public var body: some View {
        Button {
            Task {
                await service.toggleRecording()
            }
        } label: {
            Image(systemName: service.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 20))
                .foregroundStyle(service.isRecording ? .red : .accentColor)
                .frame(width: 44, height: 44)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .disabled(!service.isAvailable)
        .opacity(service.isAvailable ? 1 : 0.5)
    }
}

// MARK: - Preview

#Preview("Dictation Overlay") {
    IOSDictationOverlay(service: IOSDictationService())
        .padding()
}

#Preview("Dictation Button") {
    DictationButton(service: IOSDictationService())
        .padding()
}
