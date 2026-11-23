import AVFoundation
import PlannerKit
import Speech
import SwiftUI

/// Speech to text for the capture bar: listens until you pause, then hands back the words.
/// Recognition runs on the device when it can, so nothing leaves the phone except the final line.
@MainActor
@Observable
final class VoiceCapture {
    enum Phase: Equatable {
        case idle, listening, finished, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private let speaker = AVSpeechSynthesizer()

    /// Seconds of quiet after speech that end listening.
    var pauseToFinish: Double = 1.6

    func start() async {
        transcript = ""
        guard await Self.permissions() else {
            phase = .failed("Allow Microphone and Speech Recognition for Planner in Settings to use voice.")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            phase = .failed("Speech recognition isn't available right now.")
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            request.addsPunctuation = false
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            phase = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self, self.phase == .listening else { return }
                    if let text { self.transcript = text; self.restartSilenceTimer() }
                    if isFinal { self.finish() }
                    if error != nil, self.transcript.isEmpty { self.fail("Didn't catch that. Try again.") }
                }
            }
            restartSilenceTimer(initial: true)
        } catch {
            fail("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    /// Stop listening and keep what was heard.
    func finish() {
        guard phase == .listening else { return }
        stopAudio()
        phase = transcript.trimmingCharacters(in: .whitespaces).isEmpty ? .failed("Didn't catch that. Try again.") : .finished
    }

    func cancel() {
        stopAudio()
        phase = .idle
        transcript = ""
    }

    func speak(_ text: String) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        #endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaker.speak(utterance)
    }

    private func fail(_ message: String) {
        stopAudio()
        phase = .failed(message)
    }

    private func stopAudio() {
        silence?.cancel()
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Ends listening after a pause; gives a little longer before the first word.
    private func restartSilenceTimer(initial: Bool = false) {
        silence?.cancel()
        let wait = initial ? 6.0 : pauseToFinish
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private static func permissions() async -> Bool {
        let speech = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// The voice sheet: live words while you talk, then what Planner made of it, with Undo.
struct VoiceCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var voice = VoiceCapture()
    @State private var result: CaptureResult?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            switch voice.phase {
            case .idle, .listening:
                MicPulse(active: voice.phase == .listening)
                Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                    .frame(minHeight: 80)
                Text("Try “Write the proposal by Friday two hours #freelance” or “@Freddy balance the drawer tomorrow”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { voice.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(voice.transcript.isEmpty)
            case .finished:
                if saving {
                    ProgressView()
                    Text("“\(voice.transcript)”").foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else if let result {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                    Text(IntentClient.describe(result, projects: model.projects))
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Undo", role: .destructive) {
                            Task {
                                await model.undo(result)
                                dismiss()
                            }
                        }
                        .buttonStyle(.bordered)
                        Button("Add Another") { restart() }
                            .buttonStyle(.bordered)
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("Couldn't save “\(voice.transcript)”.").foregroundStyle(.secondary)
                    Button("Try Again") { restart() }.buttonStyle(.borderedProminent)
                }
            case .failed(let message):
                Image(systemName: "mic.slash").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") { restart() }.buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.medium])
        .task { await voice.start() }
        .onChange(of: voice.phase) { _, phase in
            guard phase == .finished, result == nil, !saving else { return }
            saving = true
            Task {
                result = await model.captureForVoice(voice.transcript)
                saving = false
                if let result { voice.speak(IntentClient.describe(result, projects: model.projects)) }
            }
        }
        .onDisappear { voice.cancel() }
        #if os(macOS)
        .frame(width: 420, height: 360)
        #endif
    }

    private func restart() {
        result = nil
        Task { await voice.start() }
    }
}

private struct MicPulse: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 120, height: 120)
                .scaleEffect(pulse && active ? 1.15 : 0.9)
                .animation(active ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 72, height: 72)
            Image(systemName: "mic.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white)
        }
        .onAppear { pulse = true }
        .accessibilityLabel(active ? "Listening" : "Microphone")
    }
}
