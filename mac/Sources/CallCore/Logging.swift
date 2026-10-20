import os

/// Log categories, viewable in Console.app under the subsystem below.
/// The copied OpenOats files log through these names.
enum Log {
    static let subsystem = "com.jaceg.callassistant"

    static let systemAudio = Logger(subsystem: subsystem, category: "system-audio")
    static let mic = Logger(subsystem: subsystem, category: "mic")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let session = Logger(subsystem: subsystem, category: "session")
}

/// The app version.
public enum AppInfo {
    public static let version = "0.1.0"
}
