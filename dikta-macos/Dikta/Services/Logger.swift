import os.log

enum AppLogger {
    static let audio = Logger(subsystem: "com.dikta", category: "audio")
    static let hotkey = Logger(subsystem: "com.dikta", category: "hotkey")
    static let config = Logger(subsystem: "com.dikta", category: "config")
    static let transcription = Logger(subsystem: "com.dikta", category: "transcription")
    static let tts = Logger(subsystem: "com.dikta", category: "tts")
    static let llm = Logger(subsystem: "com.dikta", category: "llm")
    static let general = Logger(subsystem: "com.dikta", category: "general")
}
