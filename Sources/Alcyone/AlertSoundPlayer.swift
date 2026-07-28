import Foundation
import Sterope

/// Plays Sterope's alert sounds. Protocol-first so tests can assert what
/// *would* have played without making noise.
public protocol AlertSoundPlaying: AnyObject, Sendable {
    func play(_ sound: AlertSound, volume: Double)
}

/// Records calls instead of making sound. Used by tests and by the bench
/// when you'd rather not be beeped at.
public final class SilentSoundPlayer: AlertSoundPlaying, @unchecked Sendable {
    public private(set) var played: [(sound: AlertSound, volume: Double)] = []

    public init() {}

    public func play(_ sound: AlertSound, volume: Double) {
        played.append((sound, volume))
    }
}

#if canImport(AVFoundation)
import AVFoundation

/// The real one. Built-in tones are synthesized (no asset files to ship or
/// lose); custom clips come from the sounds/ directory.
public final class SystemAlertSoundPlayer: AlertSoundPlaying, @unchecked Sendable {
    private let queue = DispatchQueue(label: "alcyone.sound")
    private var players: [AVAudioPlayer] = []
    private let soundsBase: URL?
    private var sessionConfigured = false

    public init(soundsBase: URL? = nil) {
        self.soundsBase = soundsBase
    }

    public func play(_ sound: AlertSound, volume: Double) {
        let clamped = min(max(volume, 0), 1)
        guard clamped > 0 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            switch sound {
            case .silent:
                return
            case .builtIn(let name):
                self.playData(Self.tone(named: name), volume: clamped)
            case .file:
                guard let url = AlertSoundLibrary.url(for: sound, base: self.soundsBase),
                      let data = try? Data(contentsOf: url)
                else { return }
                self.playData(data, volume: clamped)
            }
        }
    }

    private func playData(_ data: Data, volume: Double) {
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = Float(volume)
        player.prepareToPlay()
        // Reap finished players *before* appending. Never inspect `players`
        // from inside a closure that's mutating it — that's an exclusive
        // access violation, and it traps.
        players = Self.stillPlaying(players)
        players.append(player)
        player.play()
    }

    /// Which retained players are still making sound. Pure and static so the
    /// bookkeeping is testable and can't touch `self` mid-mutation.
    static func stillPlaying(_ players: [AVAudioPlayer]) -> [AVAudioPlayer] {
        players.filter(\.isPlaying)
    }

    /// On iOS the alert has to be audible over whatever's playing and
    /// regardless of the ring switch — duck the music, don't stop it.
    private func configureSessionIfNeeded() {
        #if os(iOS)
        guard !sessionConfigured else { return }
        sessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    /// Built-in tones as synthesized WAV data — a short envelope over one or
    /// two sine bursts. Distinct enough to tell apart on a dashboard.
    static func tone(named name: String) -> Data {
        switch name {
        case "urgent": return wav(bursts: [(880, 0.09), (0, 0.05), (880, 0.09), (0, 0.05), (880, 0.12)])
        case "alert": return wav(bursts: [(740, 0.12), (0, 0.06), (740, 0.16)])
        case "soft": return wav(bursts: [(523, 0.18)])
        default: return wav(bursts: [(659, 0.10), (0, 0.03), (988, 0.18)])  // "chime"
        }
    }

    /// Minimal 16-bit mono PCM WAV builder.
    static func wav(bursts: [(frequency: Double, seconds: Double)], sampleRate: Double = 44100) -> Data {
        var samples: [Int16] = []
        for burst in bursts {
            let count = Int(burst.seconds * sampleRate)
            for i in 0..<count {
                guard burst.frequency > 0 else {
                    samples.append(0)
                    continue
                }
                let t = Double(i) / sampleRate
                // Short attack, exponential decay — a tone, not a click.
                let progress = Double(i) / Double(max(count - 1, 1))
                let attack = min(progress / 0.02, 1)
                let envelope = attack * exp(-3 * progress)
                let value = sin(2 * .pi * burst.frequency * t) * envelope * 0.7
                samples.append(Int16(value * Double(Int16.max)))
            }
        }

        let dataBytes = samples.count * 2
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataBytes))
        append("WAVE")
        append("fmt ")
        append32(16)          // PCM chunk size
        append16(1)           // format: PCM
        append16(1)           // channels
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)  // byte rate
        append16(2)           // block align
        append16(16)          // bits per sample
        append("data")
        append32(UInt32(dataBytes))
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
#endif
