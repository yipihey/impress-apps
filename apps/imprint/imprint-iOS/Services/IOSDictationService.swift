//
//  IOSDictationService.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import Foundation
import Speech
import AVFoundation
import Combine
import os.log

// MARK: - iOS Dictation Service

/// Voice dictation service for imprint on iOS.
///
/// Features:
/// - Continuous speech recognition
/// - Auto-punctuation
/// - Voice commands for formatting ("bold", "italic", "new paragraph")
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

    private let logger = Logger(subsystem: "com.imbib.imprint", category: "Dictation")

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
        case newParagraph = "new paragraph"
        case headingOne = "heading one"
        case headingTwo = "heading two"
        case headingThree = "heading three"
        case bold = "bold"
        case italic = "italic"
        case code = "code"
        case bulletPoint = "bullet point"
        case numberedList = "numbered list"
        case undo = "undo"
        case stopDictation = "stop dictation"

        /// The Typst markup to insert for this command
        public var markup: String? {
            switch self {
            case .newParagraph: return "\n\n"
            case .headingOne: return "\n= "
            case .headingTwo: return "\n== "
            case .headingThree: return "\n=== "
            case .bold: return "*"
            case .italic: return "_"
            case .code: return "`"
            case .bulletPoint: return "\n- "
            case .numberedList: return "\n+ "
            case .undo, .stopDictation: return nil
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
                        continuation.resume(returning: true)
                    case .denied, .restricted, .notDetermined:
                        self.isAvailable = false
                        self.errorMessage = "Speech recognition not authorized"
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
                self.logger.error("Recognition error: \(error.localizedDescription)")
                self.stopRecording()
            }
        }

        isRecording = true
        errorMessage = nil
        logger.info("Dictation started")
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

        logger.info("Dictation stopped")
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
        logger.info("Voice command detected: \(command.rawValue)")

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
            // Undo would need to be handled by the editor
            onVoiceCommand?(command)
        default:
            onVoiceCommand?(command)
            if let markup = command.markup {
                onTextRecognized?(markup)
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

import SwiftUI

/// Visual overlay showing dictation status and waveform.
public struct IOSDictationOverlay: View {

    var service: IOSDictationService

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

// MARK: - Preview

#Preview {
    IOSDictationOverlay(service: IOSDictationService())
        .padding()
}
