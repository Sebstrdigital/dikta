import Foundation

struct FormatterEngine {
    func format(_ text: String, style: FormatterStyle) -> String {
        switch style {
        case .message:
            return MessageFormatter().format(text)
        case .structure:
            return StructuredTextFormatter().format(text)
        }
    }
}
