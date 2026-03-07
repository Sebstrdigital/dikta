import Foundation

/// Mic distance presets that control Whisper's speech detection sensitivity.
///
/// Two Whisper decoding thresholds are tuned per preset:
/// - `noSpeechThreshold`: Whisper's internal classifier score for "no speech". Higher values
///   cause Whisper to more aggressively classify audio as silence. AirPods and other Bluetooth
///   mics deliver quieter signals, triggering false "No Speech" results at the default 0.6 —
///   hence lower values for farther/headset scenarios.
/// - `logProbThreshold`: Average log-probability of output tokens. Lower (more negative) values
///   allow Whisper to accept lower-confidence transcriptions, which is needed for quiet or
///   distant microphones where per-token confidence is naturally reduced.
///
/// Values are empirically derived from testing across MacBook internal mic (close),
/// desk mic at ~50cm (normal), and AirPods/headsets (far):
/// - Close: strict thresholds suited for loud, direct input
/// - Normal: balanced defaults that work for most desk setups
/// - Far / Headset: permissive thresholds to prevent false "No Speech" from quiet Bluetooth audio
enum MicDistance: String, Codable, CaseIterable {
    case close
    case normal
    case far

    var displayName: String {
        switch self {
        case .close: return "Close"
        case .normal: return "Normal"
        case .far: return "Far / Headset"
        }
    }

    /// Whisper `noSpeechThreshold` — higher = more likely to reject quiet audio as silence.
    /// Range is 0.0–1.0; Whisper's default is 0.6.
    var noSpeechThreshold: Float {
        switch self {
        case .close: return 0.6   // Strict: matches Whisper default, good for loud direct mic
        case .normal: return 0.3  // Relaxed: avoids false negatives from desk-distance input
        case .far: return 0.15    // Permissive: required for Bluetooth/headset weak signals
        }
    }

    /// RMS energy threshold for silence detection in `AudioRecorder`.
    /// Audio chunks with RMS below this level are considered silence.
    /// Close mics produce stronger signals, so the threshold is higher to avoid false recordings.
    /// Far/headset mics produce weaker signals, so the threshold is lower to avoid premature stops.
    var silenceRMSThreshold: Float {
        switch self {
        case .close: return 0.01   // Higher: close mic delivers strong signal, silence is still loud
        case .normal: return 0.005 // Balanced: default, matches previous hardcoded value
        case .far: return 0.002    // Lower: weak Bluetooth signals need a more permissive floor
        }
    }

    /// Whisper `logProbThreshold` — lower (more negative) = accepts lower-confidence output.
    /// Whisper's default is -1.0.
    var logProbThreshold: Float {
        switch self {
        case .close: return -1.0  // Default: good confidence requirement for clean mic input
        case .normal: return -1.5 // Relaxed: allows moderate confidence drop at desk distance
        case .far: return -2.0    // Permissive: needed for AirPods where signal attenuation is high
        }
    }
}
