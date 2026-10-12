import Foundation

/// Conservative, bounded selected-text rendering with no I/O or runtime dependencies.
struct ReadAloudTextPreparer: Sendable {
    static let maximumInputBytes = 256 * 1024
    enum Kind: Equatable, Sendable { case ready, empty, unsupported }
    struct Result: Equatable, Sendable { let kind: Kind; let text: String }
    private static let horizontal = CharacterSet(charactersIn: " \t")

    func prepare(_ raw: String) -> Result {
        guard raw.lengthOfBytes(using: .utf8) <= Self.maximumInputBytes else { return .init(kind: .unsupported, text: "") }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // One full-selection presentation wrapper gets exactly one additional render pass.
        // Its interior is not recursively reconsidered as another presentation wrapper.
        let text = render(outerPresentationInterior(normalized) ?? normalized)
        guard text.lengthOfBytes(using: .utf8) <= Self.maximumInputBytes else { return .init(kind: .unsupported, text: "") }
        return text.isEmpty ? .init(kind: .empty, text: "") : .init(kind: .ready, text: text)
    }

    private func render(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = [], prose: [String] = [], i = 0
        func flush() { if !prose.isEmpty { output.append(prose.joined(separator: " ")); prose.removeAll(keepingCapacity: true) } }
        while i < lines.count {
            if let candidate = rawFence(lines[i]) {
                if let valid = validFence(lines[i]) {
                    if let close = findValidFenceClose(lines, from: i + 1, fence: valid) {
                        flush(); output.append(contentsOf: lines[(i + 1)..<close]); i = close + 1; continue
                    }
                    flush(); output.append(contentsOf: lines[i...]); break
                }
                // Invalid/over-indented candidates protect their whole paired region.
                if let close = findFenceClose(lines, from: i + 1, fence: candidate) {
                    flush(); output.append(contentsOf: lines[i...close]); i = close + 1; continue
                }
                flush(); output.append(contentsOf: lines[i...]); break
            }
            if i + 1 < lines.count, let table = table(lines, at: i) { flush(); output.append(contentsOf: table.text); i = table.end; continue }
            let line = lines[i]
            if asciiTrim(line).isEmpty { flush(); output.append(""); i += 1; continue }
            let rendered = proseLine(line)
            if rendered.boundary { flush(); output.append(rendered.text) } else { prose.append(rendered.text) }
            i += 1
        }
        flush()
        var start = 0, end = output.count
        while start < end && output[start].isEmpty { start += 1 }; while end > start && output[end - 1].isEmpty { end -= 1 }
        return output[start..<end].joined(separator: "\n")
    }

    private func outerPresentationInterior(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var first = 0, last = lines.count
        while first < last && asciiTrim(lines[first]).isEmpty { first += 1 }
        while last > first && asciiTrim(lines[last - 1]).isEmpty { last -= 1 }
        guard first < last, let fence = validFence(lines[first]) else { return nil }
        let leading = lines[first].prefix { $0 == " " }.count
        let label = asciiTrim(String(lines[first].dropFirst(leading + fence.count))).lowercased()
        guard ["text", "markdown"].contains(label), let close = findValidFenceClose(lines, from: first + 1, fence: fence), close == last - 1 else { return nil }
        return lines[(first + 1)..<close].joined(separator: "\n")
    }

    private struct Fence { let marker: Character; let count: Int }
    private func rawFence(_ line: String) -> Fence? {
        let a = Array(line); var p = 0; while p < a.count && a[p] == " " { p += 1 }
        guard p < a.count, a[p] == "`" || a[p] == "~" else { return nil }; let marker = a[p]; var q = p
        while q < a.count && a[q] == marker { q += 1 }; return q - p >= 3 ? Fence(marker: marker, count: q - p) : nil
    }
    private func validFence(_ line: String) -> Fence? {
        let leading = line.prefix { $0 == " " }.count; guard leading <= 3, let fence = rawFence(line) else { return nil }
        let a = Array(line); let p = leading + fence.count
        return fence.marker == "`" && a[p...].contains("`") ? nil : fence
    }
    private func findValidFenceClose(_ lines: [String], from: Int, fence: Fence) -> Int? {
        var i = from
        while i < lines.count { let a = Array(lines[i]); var p = 0; while p < a.count && a[p] == " " { p += 1 }
            guard p <= 3 else { i += 1; continue }
            var q = p; while q < a.count && a[q] == fence.marker { q += 1 }
            if q - p >= fence.count && a[q...].allSatisfy({ $0 == " " || $0 == "\t" }) { return i }
            i += 1 }
        return nil
    }
    private func findFenceClose(_ lines: [String], from: Int, fence: Fence) -> Int? {
        var i = from
        while i < lines.count { let a = Array(lines[i]); var p = 0; while p < a.count && a[p] == " " { p += 1 }
            if p <= 3 || rawFence(lines[i]) != nil { var q = p; while q < a.count && a[q] == fence.marker { q += 1 }
                if q - p >= fence.count && a[q...].allSatisfy({ $0 == " " || $0 == "\t" }) { return i } }
            i += 1 }
        return nil
    }

    private func table(_ lines: [String], at start: Int) -> (text: [String], end: Int)? {
        guard let head = cells(lines[start]), let divider = cells(lines[start + 1]), head.count >= 2, head.count == divider.count, divider.allSatisfy(delimiter) else { return nil }
        var result = [head.map { inline($0, table: true) }.joined(separator: "; ")], end = start + 2
        while end < lines.count, let row = cells(lines[end]), row.count == head.count { result.append(row.map { inline($0, table: true) }.joined(separator: "; ")); end += 1 }
        return (result, end)
    }
    private func delimiter(_ value: String) -> Bool {
        let a = Array(asciiTrim(value)); guard a.count >= 3 else { return false }
        var left = 0, right = a.count; if a.first == ":" { left += 1 }; if right > left && a.last == ":" { right -= 1 }
        return right - left >= 2 && a[left..<right].allSatisfy { $0 == "-" }
    }
    private func cells(_ line: String) -> [String]? {
        let a = Array(line); var result: [String] = [], current = "", i = 0, code: Int? = nil, pipe = false
        while i < a.count {
            if a[i] == "\\", i + 1 < a.count { current.append(a[i]); current.append(a[i + 1]); i += 2; continue }
            if a[i] == "`" { var j = i; while j < a.count && a[j] == "`" { j += 1 }; let n = j - i; if code == n { code = nil } else if code == nil { code = n }; current.append(contentsOf: a[i..<j]); i = j; continue }
            if a[i] == "|" && code == nil { result.append(current); current = ""; pipe = true } else { current.append(a[i]) }; i += 1
        }
        guard pipe, code == nil else { return nil }; result.append(current); let t = asciiTrim(line)
        if t.hasPrefix("|") { result.removeFirst() }; if t.hasSuffix("|") { result.removeLast() }; return result
    }

    private func proseLine(_ line: String) -> (text: String, boundary: Bool) {
        let trimmed = asciiTrim(line)
        if line.first?.isWhitespace == true, ["#", "*", "-", "+"].contains(trimmed) { return (line, true) }
        if ["#", "*", "-", "+"].contains(trimmed), line.contains(where: { $0 == " " || $0 == "\t" }) { return ("", true) }
        var value = trimmed, boundary = value.contains("|")
        let a = Array(value); var h = 0; while h < a.count && a[h] == "#" { h += 1 }
        if h > 0 && h < a.count && a[h] == " " { value = String(a[(h + 1)...]); boundary = true }
        let b = Array(value); var p = 0; while p < b.count && b[p] == " " { p += 1 }
        if p + 1 < b.count && ["-", "+", "*"].contains(b[p]) && (b[p + 1] == " " || b[p + 1] == "\t") { value = String(b[(p + 2)...]); boundary = true }
        else if p < b.count && b[p].isNumber { var q = p; while q < b.count && b[q].isNumber { q += 1 }; if q + 1 < b.count && b[q] == "." && (b[q + 1] == " " || b[q + 1] == "\t") { boundary = true } }
        return (inline(value, table: false), boundary)
    }

    private struct Run { let marker: Character; let length: Int; let end: Int; let next: Int? }
    /// Tokenizes each marker run once and reverse-indexes the next exact run.
    private func inline(_ value: String, table: Bool) -> String {
        let a = Array(asciiTrim(value));
        if table && a.indices.contains(where: { index in a[index] == "\\" && index + 1 < a.count && ["`", "*", "_"].contains(a[index + 1]) }) {
            // Ambiguous escaped presentation markers make the whole trimmed cell literal.
            return asciiTrim(value)
        }
        // Code spans are paired first. Their complete interiors are excluded from
        // emphasis links, so code punctuation cannot close an outer emphasis run.
        if !table && a.indices.contains(where: { index in a[index] == "\\" && index + 1 < a.count && ["`", "*", "_"].contains(a[index + 1]) }) { return asciiTrim(value) }
        var starts: [Int: Run] = [:], nextByKey: [String: Int] = [:], raw: [(Int, Character, Int)] = [], i = 0
        while i < a.count {
            if a[i] == "\\", i + 1 < a.count { i += 2; continue }
            if ["`", "*", "_"].contains(a[i]) { var j = i; while j < a.count && a[j] == a[i] { j += 1 }; raw.append((i, a[i], j - i)); i = j } else { i += 1 }
        }
        // Reverse indexing is O(token count). A forward cursor then chooses
        // non-overlapping confirmed code spans and marks their interiors once.
        var nextTick: [String: Int] = [:], candidateTickLinks: [Int: Int] = [:]
        for token in raw.reversed() where token.1 == "`" { let key = "`\(token.2)"; if let next = nextTick[key] { candidateTickLinks[token.0] = next }; nextTick[key] = token.0 }
        var codeLinks: [Int: Int] = [:], spans: [(Int, Int)] = [], tokenIndex = 0
        while tokenIndex < raw.count { let token = raw[tokenIndex]
            if token.1 == "`", let close = candidateTickLinks[token.0] {
                codeLinks[token.0] = close; spans.append((token.0, close))
                while tokenIndex < raw.count && raw[tokenIndex].0 <= close { tokenIndex += 1 }
            } else { tokenIndex += 1 }
        }
        var protected = Set<Int>(), spanIndex = 0
        for token in raw {
            while spanIndex < spans.count && token.0 >= spans[spanIndex].1 { spanIndex += 1 }
            if spanIndex < spans.count && token.0 > spans[spanIndex].0 && token.0 < spans[spanIndex].1 { protected.insert(token.0) }
        }
        for token in raw.reversed() { let key = "\(token.1)\(token.2)"; let next = token.1 == "`" ? codeLinks[token.0] : nextByKey[key]; starts[token.0] = Run(marker: token.1, length: token.2, end: token.0 + token.2, next: next); if token.1 != "`" && !protected.contains(token.0) { nextByKey[key] = token.0 } }
        var out = "", space = false; i = 0
        func prose(_ c: Character) { if space && !out.isEmpty { out.append(" ") }; space = false; out.append(c) }
        while i < a.count {
            if let run = starts[i], let close = run.next, run.marker == "`" { if space && !out.isEmpty { out.append(" ") }; space = false; out.append(contentsOf: a[run.end..<close]); i = starts[close]!.end; continue }
            if let run = starts[i], run.marker != "`", run.length <= 2, let close = run.next, emphasisFlanks(a, open: run, close: starts[close]!) {
                if space && !out.isEmpty { out.append(" ") }; space = false
                out += inline(String(a[run.end..<close]), table: table); i = starts[close]!.end; continue
            }
            if a[i] == " " || a[i] == "\t" { space = true; i += 1; continue }
            if table && a[i] == "\\" && i + 1 < a.count && a[i + 1] == "|" { prose("|"); i += 2; continue }
            prose(a[i]); i += 1
        }; return out
    }
    private func emphasisFlanks(_ a: [Character], open: Run, close: Run) -> Bool {
        let before = open.end < a.count ? a[open.end] : " ", prior = open.end > open.length ? a[open.end - open.length - 1] : " "
        let beforeClose = close.end > close.length ? a[close.end - close.length - 1] : " ", after = close.end < a.count ? a[close.end] : " "
        return !before.isWhitespace && !prior.isLetter && !prior.isNumber && !beforeClose.isWhitespace && !after.isLetter && !after.isNumber
    }
    private func asciiTrim(_ value: String) -> String { value.trimmingCharacters(in: Self.horizontal) }
}
