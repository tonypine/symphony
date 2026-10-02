/// Splits a command line into words the way a POSIX shell does for quoting,
/// without expanding variables, globs or other substitutions.
public enum ShellWords {
    /// Returns the words in `line`, or `nil` when a quote is left open or the line ends with a lone backslash.
    public static func split(_ line: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            switch character {
            case "'":
                inWord = true
                guard let quoted = readUntil("'", from: &iterator, escapes: false) else { return nil }
                current += quoted
            case "\"":
                inWord = true
                guard let quoted = readUntil("\"", from: &iterator, escapes: true) else { return nil }
                current += quoted
            case "\\":
                guard let escaped = iterator.next() else { return nil }
                inWord = true
                current.append(escaped)
            case _ where character.isWhitespace:
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                inWord = true
                current.append(character)
            }
        }

        if inWord { words.append(current) }
        return words
    }

    /// Quotes `word` so a POSIX shell reads it back as exactly one word. Plain words are left as they are.
    public static func quote(_ word: String) -> String {
        let plain = !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || "-_./=:,+@%".unicodeScalars.contains(scalar)
        }
        if plain { return word }
        return "'" + word.map { $0 == "'" ? "'\\''" : String($0) }.joined() + "'"
    }

    private static func readUntil(
        _ terminator: Character,
        from iterator: inout String.Iterator,
        escapes: Bool
    ) -> String? {
        var text = ""
        while let character = iterator.next() {
            if character == terminator { return text }
            if escapes && character == "\\" {
                guard let escaped = iterator.next() else { return nil }
                // Inside double quotes a backslash only escapes $, `, ", \ and newline.
                if !"$`\"\\\n".contains(escaped) { text.append("\\") }
                text.append(escaped)
            } else {
                text.append(character)
            }
        }
        return nil
    }
}
