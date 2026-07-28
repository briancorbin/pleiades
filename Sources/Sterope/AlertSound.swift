import Foundation

/// What a rule sounds like when it fires. Alcyone plays this — it does not
/// replace the car's own chime (see docs/design/chimes.md); it's our layer
/// on top, and the only audio in the system we actually control.
public enum AlertSound: Sendable, Equatable, Hashable, Codable {
    /// Banner only, no audio.
    case silent
    /// One of the built-in tones, by name.
    case builtIn(String)
    /// A user-supplied file in the app's `sounds/` directory.
    case file(String)

    public var displayName: String {
        switch self {
        case .silent: return "Silent"
        case .builtIn(let name): return name.capitalized
        case .file(let name): return name
        }
    }

    /// The stock tones every install has.
    public static let builtInNames = ["chime", "alert", "urgent", "soft"]

    public static let allBuiltIns: [AlertSound] = [.silent] + builtInNames.map { .builtIn($0) }
}

/// Where user-supplied clips live. Drop .caf/.wav/.mp3 files here and they
/// show up in the rule editor.
public enum AlertSoundLibrary {
    public static func directory(base: URL? = nil) -> URL {
        let root = base ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pleiades", isDirectory: true)
        let dir = root.appendingPathComponent("sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Custom clips currently installed, by filename.
    public static func customSounds(base: URL? = nil) -> [AlertSound] {
        let dir = directory(base: base)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["caf", "wav", "mp3", "m4a", "aiff"].contains($0.pathExtension.lowercased()) }
            .map { .file($0.lastPathComponent) }
            .sorted { $0.displayName < $1.displayName }
    }

    public static func url(for sound: AlertSound, base: URL? = nil) -> URL? {
        guard case .file(let name) = sound else { return nil }
        return directory(base: base).appendingPathComponent(name)
    }
}
