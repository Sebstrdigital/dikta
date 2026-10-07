import Foundation

@MainActor
protocol TextSelectionProviding: AnyObject {
    func getSelectedText() -> String?
    func getSelectedTextViaClipboard() async -> String?
}

extension TextSelectionService: TextSelectionProviding {
    func getSelectedTextViaClipboard() async -> String? {
        await getSelectedTextViaClipboard(
            modifierTimeout: 1.5,
            copyWait: 0.5,
            pollInterval: 0.02
        )
    }
}
