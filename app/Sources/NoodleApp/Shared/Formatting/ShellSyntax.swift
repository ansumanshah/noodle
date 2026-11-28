import Foundation

/// Lossless highlighting for shell command snippets, not a shell parser or evaluator.
enum ShellSyntax {
    enum Kind: Sendable, Equatable {
        case prompt, command, flag, string, variable, `operator`, comment, argument
    }

    struct Token: Sendable, Equatable {
        let kind: Kind
        let text: String
    }

    /// Whitespace is an argument token. Quotes and escapes retain their original spelling.
    static func tokenize(_ input: String) -> [Token] {
        var scanner = Scanner(characters: Array(input))
        return scanner.scan()
    }

    private struct Scanner {
        let characters: [Character]
        var index = 0
        var tokens: [Token] = []
        var needsCommand = true
        var redirectTarget = false
        var lineStart = true

        func char(_ offset: Int = 0) -> Character? {
            let position = index + offset
            return position < characters.count ? characters[position] : nil
        }

        mutating func emit(_ kind: Kind, from start: Int) {
            guard index > start else { return }
            tokens.append(Token(kind: kind, text: String(characters[start..<index])))
        }

        mutating func scan(untilClosingParenthesis: Bool = false) -> [Token] {
            var groupDepth = 0
            while let current = char() {
                if untilClosingParenthesis, current == ")", groupDepth == 0 { break }
                let start = index
                if current.isWhitespace {
                    while let next = char(), next.isWhitespace {
                        if next.isNewline { needsCommand = true; redirectTarget = false; lineStart = true }
                        index += 1
                    }
                    emit(.argument, from: start)
                } else if lineStart, current == "$" || current == "%", char(1) == " " {
                    index += 1
                    emit(.prompt, from: start)
                    lineStart = false
                } else if current == "#" {
                    while let next = char(), !next.isNewline { index += 1 }
                    emit(.comment, from: start)
                } else if current == "\\", char(1)?.isNewline == true {
                    index += 2
                    emit(.argument, from: start)
                } else if scanOperator() {
                    if current == "(" { groupDepth += 1 }
                    if current == ")" { groupDepth -= 1 }
                    lineStart = false
                } else {
                    scanWord()
                    lineStart = false
                }
            }
            return tokens
        }

        mutating func scanOperator() -> Bool {
            let start = index
            var cursor = index
            while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
            if cursor == characters.count || !"<>".contains(characters[cursor]) { cursor = index }
            guard cursor < characters.count, "|&;()<>".contains(characters[cursor]) else { return false }
            let first = characters[cursor]
            index = cursor + 1
            if let next = char(), ["||", "&&", ";;", "<<", ">>", "<&", ">&", "<>", ">|", "|&"]
                .contains(String([first, next])) { index += 1 }
            if first == "<", index - cursor == 2, characters[cursor + 1] == "<", char() == "-" {
                index += 1
            }
            emit(.operator, from: start)
            redirectTarget = first == "<" || first == ">"
            if !redirectTarget { needsCommand = true }
            return true
        }

        func isNameStart(_ character: Character) -> Bool {
            character == "_" || character.isASCII && character.isLetter
        }

        func isNamePart(_ character: Character) -> Bool {
            isNameStart(character) || character.isASCII && character.isNumber
        }

        func isAssignment() -> Bool {
            guard let first = char(), isNameStart(first) else { return false }
            var cursor = index + 1
            while cursor < characters.count, isNamePart(characters[cursor]) { cursor += 1 }
            return cursor < characters.count && characters[cursor] == "="
        }

        mutating func scanWord() {
            let assignment = needsCommand && isAssignment()
            let kind: Kind = redirectTarget || assignment ? .argument
                : needsCommand ? .command : char() == "-" ? .flag : .argument
            var start = index
            while let current = char(), !current.isWhitespace, !"|&;()<>".contains(current) {
                if current == "\\" {
                    index += min(2, characters.count - index)
                } else if current == "'" || current == "\"" {
                    emit(kind, from: start)
                    scanQuote(current)
                    start = index
                } else if current == "$" {
                    emit(kind, from: start)
                    scanVariable(fallback: kind)
                    start = index
                } else {
                    index += 1
                }
            }
            emit(kind, from: start)
            if !assignment && !redirectTarget { needsCommand = false }
            redirectTarget = false
        }

        mutating func scanQuote(_ quote: Character) {
            var start = index
            index += 1
            while let current = char() {
                if current == quote {
                    index += 1
                    break
                } else if quote == "\"", current == "\\",
                          let next = char(1), "\"\\$`".contains(next) || next.isNewline {
                    index += 2
                } else if quote == "\"", current == "$" {
                    emit(.string, from: start)
                    scanVariable(fallback: .string)
                    start = index
                } else {
                    index += 1
                }
            }
            emit(.string, from: start)
        }

        mutating func scanVariable(fallback: Kind) {
            let start = index
            index += 1
            guard let next = char() else { emit(fallback, from: start); return }
            if next == "(" {
                index += 1
                emit(.operator, from: start)
                let context = (needsCommand, redirectTarget, lineStart)
                needsCommand = true
                redirectTarget = false
                lineStart = false
                _ = scan(untilClosingParenthesis: true)
                let close = index
                if char() == ")" { index += 1; emit(.operator, from: close) }
                (needsCommand, redirectTarget, lineStart) = context
                return
            } else if next == "{" {
                index += 1
                while let current = char(), current != "}", current != "\"", !current.isNewline {
                    if current == "\\", char(1) != nil { index += 1 }
                    index += 1
                }
                if char() == "}" { index += 1 }
            } else if isNameStart(next) {
                repeat { index += 1 } while char().map(isNamePart) == true
            } else if "0123456789?@*#$!-".contains(next) {
                index += 1
            } else {
                emit(fallback, from: start)
                return
            }
            emit(.variable, from: start)
        }
    }
}
