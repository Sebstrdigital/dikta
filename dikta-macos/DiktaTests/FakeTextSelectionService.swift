import Foundation
@testable import Dikta

@MainActor
final class FakeTextSelectionService: TextSelectionProviding {
    var selectedText: String? = "Synthetic selection"
    var clipboardText: String?
    var clipboardCapture: (() async -> String?)?
    private(set) var clipboardCalls = 0
    func getSelectedText() -> String? { selectedText }
    func getSelectedTextViaClipboard() async -> String? {
        clipboardCalls += 1
        if let clipboardCapture { return await clipboardCapture() }
        return clipboardText
    }
}
