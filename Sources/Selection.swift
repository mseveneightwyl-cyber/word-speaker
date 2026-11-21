import Foundation

struct Selection: Equatable {
    let text: String
    let identity: String

    static func english(_ raw: String, identity: String) -> Selection? {
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty, text.count <= 160,
              text.split(separator: " ").count <= 20,
              text.range(of: "[A-Za-z]", options: .regularExpression) != nil,
              text.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 '-’.,!?():;/\"–—").contains(scalar)
              }) else { return nil }
        return Selection(text: text, identity: identity)
    }
}

/// Speak only after the same selection is observed twice. Losing a selection
/// re-arms it, so selecting the same word again plays it again.
struct SelectionGate {
    private var pending: Selection?
    private var spoken: Selection?

    mutating func update(_ selection: Selection?) -> String? {
        guard let selection else {
            reset()
            return nil
        }
        guard pending == selection else {
            pending = selection
            return nil
        }
        guard spoken != selection else { return nil }
        spoken = selection
        return selection.text
    }

    mutating func interrupt() { pending = nil }
    mutating func reset() { pending = nil; spoken = nil }
}
