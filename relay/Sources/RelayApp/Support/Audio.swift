import AVFoundation
import Foundation
import RelayAdapters

/// Push-to-talk recorder. Records AAC (m4a, 16 kHz mono) to a temporary file that the app
/// deletes as soon as transcription finishes.
@MainActor
final class AudioRecorder {
    enum RecorderError: Error, CustomStringConvertible {
        case couldNotStart
        var description: String { "The microphone could not start recording" }
    }

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    /// Current microphone authorisation, without prompting.
    static var permission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-ptt-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        guard newRecorder.record() else { throw RecorderError.couldNotStart }
        recorder = newRecorder
        fileURL = url
    }

    /// Stops recording and returns the file and its duration.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let fileURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        return (fileURL, duration)
    }

    /// Stops and deletes the recording without using it.
    func cancel() {
        if let result = stop() { try? FileManager.default.removeItem(at: result.url) }
    }
}

/// Plays synthesized replies and reports when playback ends.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    var isPlaying: Bool { player?.isPlaying ?? false }

    func play(_ data: Data, onFinish: @escaping () -> Void) throws {
        stop()
        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = self
        self.onFinish = onFinish
        player = newPlayer
        newPlayer.play()
    }

    func stop() {
        player?.stop()
        player = nil
        onFinish = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finish() }
    }

    private func finish() {
        let callback = onFinish
        onFinish = nil
        player = nil
        callback?()
    }
}
