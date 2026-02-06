import Foundation
import Carbon.HIToolbox
import Cocoa

/// Delegate for hotkey events
protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyPressed()
    func hotkeyReleased()
    func hotkeyRecorded(modifiers: [ModifierKey], key: String?)
    func ttsHotkeyPressed()
    func hotkeyManagerDidFailToStart(_ error: String)
}

/// Service for managing global hotkeys using CGEventTap
final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var hotkeyConfig: HotkeyConfig
    private var hotkeyMode: HotkeyMode
    private var isHotkeyActive = false

    // TTS hotkey (always trigger-based, no toggle/PTT modes)
    private var ttsHotkeyConfig: HotkeyConfig = .defaultTextToSpeech
    private var isTtsHotkeyActive = false

    // Hotkey recording state
    private var isRecordingHotkey = false
    private var recordedModifiers: Set<ModifierKey> = []
    private var recordedKey: String?

    init() {
        self.hotkeyConfig = .defaultToggle
        self.hotkeyMode = .toggle
    }

    /// Update the dictation hotkey configuration
    func updateConfig(_ config: HotkeyConfig, mode: HotkeyMode) {
        self.hotkeyConfig = config
        self.hotkeyMode = mode
    }

    /// Update the TTS hotkey configuration
    func updateTtsConfig(_ config: HotkeyConfig) {
        self.ttsHotkeyConfig = config
    }

    /// Start listening for global hotkeys
    func start() {
        guard eventTap == nil else { return }

        // We need both keyDown and flagsChanged events
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)

        // Create event tap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleEvent(type: type, event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            let error = "Failed to create event tap. Check Input Monitoring permissions."
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.hotkeyManagerDidFailToStart(error)
            }
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// Stop listening for hotkeys
    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Start recording a new hotkey
    func startRecordingHotkey() {
        isRecordingHotkey = true
        recordedModifiers.removeAll()
        recordedKey = nil
    }

    /// Stop recording hotkey
    func stopRecordingHotkey() {
        isRecordingHotkey = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // Re-enable tap if macOS disabled it (e.g. after sleep/timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let flags = event.flags

        if isRecordingHotkey {
            handleHotkeyRecording(type: type, event: event, flags: flags)
            return
        }

        // Check for modifier-only hotkeys on flagsChanged
        if type == .flagsChanged {
            handleModifierEvent(flags: flags)
            return
        }

        // Handle regular key events with modifiers
        if type == .keyDown || type == .keyUp {
            handleKeyEvent(type: type, event: event, flags: flags)
        }
    }

    private func handleHotkeyRecording(type: CGEventType, event: CGEvent, flags: CGEventFlags) {
        // Track modifiers
        for modifier in ModifierKey.allCases {
            if flags.contains(modifier.cgEventFlag) {
                recordedModifiers.insert(modifier)
            }
        }

        // If a regular key is pressed, finish recording
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if let key = keyCodeToString(UInt16(keyCode)) {
                recordedKey = key
                finishHotkeyRecording()
            }
        }

        // If all modifiers released without a key, finish with modifiers only
        if type == .flagsChanged && !recordedModifiers.isEmpty {
            let anyModifierPressed = ModifierKey.allCases.contains { flags.contains($0.cgEventFlag) }
            if !anyModifierPressed {
                finishHotkeyRecording()
            }
        }
    }

    private func finishHotkeyRecording() {
        guard !recordedModifiers.isEmpty else { return }

        isRecordingHotkey = false
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.hotkeyRecorded(
                modifiers: Array(self.recordedModifiers),
                key: self.recordedKey
            )
        }
    }

    private func handleModifierEvent(flags: CGEventFlags) {
        // Check TTS hotkey (modifier-only, trigger-based)
        if ttsHotkeyConfig.key == nil {
            let ttsMatches = ttsHotkeyConfig.matchesModifiers(flags)
            if ttsMatches && !isTtsHotkeyActive {
                isTtsHotkeyActive = true
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.ttsHotkeyPressed()
                }
            } else if !ttsMatches && isTtsHotkeyActive {
                isTtsHotkeyActive = false
            }
        }

        // Check dictation hotkey (modifier-only)
        if hotkeyConfig.key == nil {
            let matches = hotkeyConfig.matchesModifiers(flags)

            if hotkeyMode == .toggle {
                // Toggle mode: trigger on press
                if matches && !isHotkeyActive {
                    isHotkeyActive = true
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.hotkeyPressed()
                    }
                } else if !matches && isHotkeyActive {
                    isHotkeyActive = false
                }
            } else {
                // Push-to-talk mode
                if matches && !isHotkeyActive {
                    isHotkeyActive = true
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.hotkeyPressed()
                    }
                } else if !matches && isHotkeyActive {
                    isHotkeyActive = false
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.hotkeyReleased()
                    }
                }
            }
        }
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent, flags: CGEventFlags) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let pressedKey = keyCodeToString(UInt16(keyCode)) else { return }

        // Check TTS hotkey (key-based, trigger-based)
        if let ttsKey = ttsHotkeyConfig.key,
           pressedKey.lowercased() == ttsKey.lowercased(),
           ttsHotkeyConfig.matchesModifiers(flags),
           type == .keyDown {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.ttsHotkeyPressed()
            }
            return
        }

        // Check dictation hotkey (key-based)
        guard let requiredKey = hotkeyConfig.key,
              pressedKey.lowercased() == requiredKey.lowercased(),
              hotkeyConfig.matchesModifiers(flags) else {
            return
        }

        if type == .keyDown {
            if hotkeyMode == .toggle {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyPressed()
                }
            } else if !isHotkeyActive {
                isHotkeyActive = true
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyPressed()
                }
            }
        } else if type == .keyUp && hotkeyMode == .pushToTalk && isHotkeyActive {
            isHotkeyActive = false
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.hotkeyReleased()
            }
        }
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String? {
        // Common key codes to characters
        let keyMap: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h",
            5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3",
            21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
            31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
            37: "l", 38: "j", 39: "'", 40: "k", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "n", 46: "m",
            47: ".", 50: "`"
        ]
        return keyMap[keyCode]
    }
}
