import Foundation

/// Drives the pre-join page to admission by polling one JS snippet through whatever
/// transport the host has (WKWebView `evaluateJavaScript` or CDP `Runtime.evaluate`).
/// Both hosts share this, so they emit identical state sequences.
struct ShadowJoinDriver {
    /// Evaluates a JS expression in the page and returns its string result.
    let evaluate: (String) async throws -> String
    var pollInterval: Duration = .milliseconds(250)
    /// Budget for finding the name field / join button.
    var controlsTimeout: Duration = .seconds(45)
    /// Backstop only. The view model's admission watch is the real deadline (it offers
    /// "keep waiting or switch"); a driver failure here would discard the recorded Me track.
    var admissionTimeout: Duration = .seconds(12 * 3600)

    private struct Config: Encodable {
        let name: String
        let selectors: ShadowSelectors
    }

    /// One poll: fills the name, dismisses the media prompt, presses ask-to-join, and
    /// reports the phase: unknown | joining | waiting | admitted | denied.
    static func script(name: String, selectors: ShadowSelectors) -> String {
        let cfg = (try? JSONEncoder().encode(Config(name: name, selectors: selectors)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function (cfg) {
          var s = cfg.selectors, q = function (c) { try { return document.querySelector(c); } catch (e) { return null; } };
          var body = ((document.body && document.body.innerText) || '').toLowerCase();
          var has = function (list) { return list.some(function (t) { return body.indexOf(t.toLowerCase()) >= 0; }); };
          if (s.admittedCSS.some(function (c) { return q(c); })) return 'admitted';
          if (has(s.deniedTexts)) return 'denied';
          if (has(s.lobbyTexts)) return 'waiting';
          var buttons = Array.prototype.slice.call(document.querySelectorAll('button,[role=button]'));
          var byText = function (list) {
            return buttons.filter(function (b) {
              var t = (b.textContent || '').trim().toLowerCase();
              return list.some(function (x) { return t.indexOf(x.toLowerCase()) >= 0; });
            })[0];
          };
          var dismiss = byText(s.dismissMediaTexts);
          if (dismiss) { dismiss.click(); return 'joining'; }
          var field = null;
          for (var i = 0; i < s.nameFieldCSS.length && !field; i++) field = q(s.nameFieldCSS[i]);
          if (!field) return 'unknown';
          if (field.value !== cfg.name) {
            var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            setter.call(field, cfg.name);
            field.dispatchEvent(new Event('input', { bubbles: true }));
            field.dispatchEvent(new Event('change', { bubbles: true }));
          }
          var join = byText(s.joinButtonTexts);
          if (!join) return 'unknown';
          join.click();
          return 'joining';
        })(\(cfg))
        """
    }

    /// Emits `.waitingForAdmission` then `.admitted`, or `.failed`. The caller emits
    /// `.joining` before calling. Returns early (silently) when the task is cancelled.
    func run(name: String, selectors: ShadowSelectors, emit: (ShadowJoinState) -> Void) async {
        let script = Self.script(name: name, selectors: selectors)
        let clock = ContinuousClock()
        let start = clock.now
        var waitingSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            let phase = (try? await evaluate(script)) ?? "unknown"
            switch phase {
            case "admitted":
                if waitingSince == nil { emit(.waitingForAdmission) }
                emit(.admitted)
                return
            case "denied":
                emit(.failed(.denied))
                return
            case "waiting":
                if waitingSince == nil {
                    waitingSince = clock.now
                    emit(.waitingForAdmission)
                }
            default:
                break
            }
            if let since = waitingSince {
                if clock.now - since > admissionTimeout { emit(.failed(.admissionTimedOut)); return }
            } else if clock.now - start > controlsTimeout {
                emit(.failed(.joinControlsNotFound))
                return
            }
            try? await Task.sleep(for: pollInterval)
        }
    }
}
