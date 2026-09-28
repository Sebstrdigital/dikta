import Foundation

/// Once admitted, polls one JS snippet for the participant list and the active speaker
/// and turns changes into `ShadowEvent`s. Shared by both hosts like `ShadowJoinDriver`.
struct ShadowSpeakerPoller {
    /// Evaluates a JS expression in the page and returns its string result.
    let evaluate: (String) async throws -> String
    var pollInterval: Duration = .milliseconds(250)

    /// What one poll saw.
    struct Snapshot: Equatable {
        var participants: [String]
        var speaker: String?
    }

    /// Diffs successive snapshots into events. Pure so it can be tested without a page.
    struct Tracker {
        private var participants: [String] = []
        private var speaker: String?

        /// Order: joined, active speaker, left.
        mutating func ingest(_ snap: Snapshot) -> [ShadowEvent] {
            var events: [ShadowEvent] = []
            for name in snap.participants where !participants.contains(name) {
                events.append(.participantJoined(name))
            }
            if snap.speaker != speaker { events.append(.activeSpeaker(snap.speaker)) }
            for name in participants where !snap.participants.contains(name) {
                events.append(.participantLeft(name))
            }
            participants = snap.participants
            speaker = snap.speaker
            return events
        }
    }

    private struct Config: Encodable {
        let selectors: ShadowSelectors
    }

    /// Returns JSON `{ok, participants, speaker}`; `ok` is false when no participant tile matched.
    static func script(selectors: ShadowSelectors) -> String {
        let cfg = (try? JSONEncoder().encode(Config(selectors: selectors)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function (cfg) {
          var s = cfg.selectors;
          var all = function (root, list) {
            var out = [];
            list.forEach(function (c) {
              try { Array.prototype.forEach.call(root.querySelectorAll(c), function (e) { if (out.indexOf(e) < 0) out.push(e); }); } catch (e) {}
            });
            return out;
          };
          var first = function (root, list) { var m = all(root, list); return m.length ? m[0] : null; };
          var tiles = all(document, s.participantCSS);
          if (!tiles.length) return JSON.stringify({ ok: false });
          var speaker = null, names = [];
          tiles.forEach(function (t) {
            var el = first(t, s.participantNameCSS) || t;
            var name = (el.textContent || '').trim();
            if (!name) return;
            names.push(name);
            var speaking = false;
            s.activeSpeakerCSS.forEach(function (c) {
              try { if (t.matches(c) || t.querySelector(c)) speaking = true; } catch (e) {}
            });
            if (speaking && speaker === null) speaker = name;
          });
          return JSON.stringify({ ok: true, participants: names, speaker: speaker });
        })(\(cfg))
        """
    }

    static func parse(_ json: String) -> Snapshot? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true,
              let names = obj["participants"] as? [String] else { return nil }
        return Snapshot(participants: names, speaker: obj["speaker"] as? String)
    }

    /// Runs until the task is cancelled. An unrecognised DOM logs one SHADOW_DOM warning
    /// and polling carries on; it never ends the run.
    func run(selectors: ShadowSelectors, emit: (ShadowEvent) -> Void) async {
        let script = Self.script(selectors: selectors)
        var tracker = Tracker()
        var warned = false
        while !Task.isCancelled {
            let raw = try? await evaluate(script)
            if let snap = raw.flatMap(Self.parse) {
                tracker.ingest(snap).forEach(emit)
            } else if !warned {
                warned = true
                let message = "SHADOW_DOM | participant list not recognised, speaker capture idle"
                DiagnosticLogger.shared.log(message)
                emit(.pageWarning(message))
            }
            try? await Task.sleep(for: pollInterval)
        }
    }
}

/// Appends each speaker change as one JSON line to `speakers.jsonl`, straight to disk.
final class SpeakerTimelineRecorder {
    private struct Line: Encodable {
        let t: Double
        let kind: String
        let name: String?
        enum CodingKeys: String, CodingKey { case t, kind, name }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(t, forKey: .t)
            try c.encode(kind, forKey: .kind)
            try c.encode(name, forKey: .name)   // explicit null when nobody is speaking
        }
    }

    private let handle: FileHandle?
    private let origin: ContinuousClock.Instant
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// `origin` is t = 0; pass the instant the audio capture started so timelines line up.
    init(fileURL: URL, origin: ContinuousClock.Instant = .now) {
        self.origin = origin
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        if handle == nil { DiagnosticLogger.shared.log("SHADOW_TIMELINE | open_failed | \(fileURL.lastPathComponent)") }
    }

    func record(_ event: ShadowEvent) {
        let kind: String
        let name: String?
        switch event {
        case .activeSpeaker(let n): kind = "activeSpeaker"; name = n
        case .participantJoined(let n): kind = "joined"; name = n
        case .participantLeft(let n): kind = "left"; name = n
        default: return
        }
        let d = (ContinuousClock.now - origin).components
        let t = ((Double(d.seconds) + Double(d.attoseconds) / 1e18) * 1000).rounded() / 1000
        guard var data = try? encoder.encode(Line(t: t, kind: kind, name: name)) else { return }
        data.append(0x0A)
        try? handle?.write(contentsOf: data)
    }

    /// Records until the stream finishes.
    func consume(_ events: AsyncStream<ShadowEvent>) async {
        for await event in events { record(event) }
        close()
    }

    func close() { try? handle?.close() }
}
