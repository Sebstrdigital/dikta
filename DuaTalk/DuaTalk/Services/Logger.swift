import os.log

enum AppLogger {
    static let audio = Logger(subsystem: "com.duatalk", category: "audio")
    static let hotkey = Logger(subsystem: "com.duatalk", category: "hotkey")
    static let config = Logger(subsystem: "com.duatalk", category: "config")
    static let transcription = Logger(subsystem: "com.duatalk", category: "transcription")
    static let tts = Logger(subsystem: "com.duatalk", category: "tts")
    static let general = Logger(subsystem: "com.duatalk", category: "general")
}
