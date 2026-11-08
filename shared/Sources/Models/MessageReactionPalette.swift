import Foundation

enum MessageReactionPalette {
    static let defaults = ["❤️", "👍", "👎", "😂", "😢", "‼️"]

    static func name(for emoji: String) -> String {
        switch emoji {
        case "❤️": "Heart"
        case "👍": "Thumbs up"
        case "👎": "Thumbs down"
        case "😂": "Laughing"
        case "😢": "Sad face"
        case "‼️": "Double exclamation"
        case "❓": "Question mark"
        default: emoji
        }
    }
}
