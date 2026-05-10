import Foundation

/// Splits a markdown document into blocks of plain markdown and Mermaid fenced code blocks.
///
/// The parser is intentionally conservative and only extracts Mermaid fences whose opening line
/// uses backticks or tildes with a fence length of at least 3 and whose first info token equals
/// "mermaid" (case-insensitive).
///
/// Non-Mermaid fenced code blocks are left inside the returned `.markdown` blocks unchanged.
enum NativeMarkdownDocumentParser {
    enum Block: Equatable, Sendable {
        case markdown(String)
        /// Mermaid diagram source (contents inside the fence, excluding the fence lines).
        case mermaid(String)

        var markdownText: String {
            switch self {
            case let .markdown(text): text
            case let .mermaid(source): source
            }
        }
    }

    /// A parsed document block tagged with its source line span (1-based, inclusive).
    ///
    /// This is used by the native markdown preview to map rendered blocks back onto
    /// `MarkdownSyncAnchor` IDs for scroll sync.
    struct SpannedBlock: Equatable, Sendable, Identifiable {
        let id: Int
        let block: Block
        let startLine: Int
        let endLine: Int

        var markdownText: String { block.markdownText }
    }

    private struct MermaidFenceClose {
        let codeEnd: String.Index
        let afterClose: String.Index
        let closeLine: Int
    }

    static func parse(_ markdown: String) -> [Block] {
        parseSpanned(markdown).map(\.block)
    }

    static func parseSpanned(_ markdown: String) -> [SpannedBlock] {
        guard !markdown.isEmpty else {
            return [SpannedBlock(id: 0, block: .markdown(""), startLine: 1, endLine: 1)]
        }

        var blocks: [SpannedBlock] = []
        blocks.reserveCapacity(4)

        let end = markdown.endIndex
        var cursor = markdown.startIndex
        var currentLine = 1

        var markdownSegmentStartIndex = cursor
        var markdownSegmentStartLine = currentLine

        func flushMarkdown(upTo index: String.Index, endLine: Int) {
            guard index > markdownSegmentStartIndex else { return }
            let text = String(markdown[markdownSegmentStartIndex ..< index])
            if case let .markdown(lastText) = blocks.last?.block {
                let last = blocks[blocks.count - 1]
                blocks[blocks.count - 1] = SpannedBlock(
                    id: last.id,
                    block: .markdown(lastText + text),
                    startLine: last.startLine,
                    endLine: max(last.endLine, endLine)
                )
            } else {
                blocks.append(
                    SpannedBlock(
                        id: blocks.count,
                        block: .markdown(text),
                        startLine: markdownSegmentStartLine,
                        endLine: max(markdownSegmentStartLine, endLine)
                    )
                )
            }
        }

        while cursor < end {
            // Current line range: [lineStart, lineEnd) where lineEnd includes newline if present.
            let lineStartIndex = cursor
            let lineStartLine = currentLine

            var lineEndIndex = cursor
            while lineEndIndex < end, !markdown[lineEndIndex].isNewline {
                lineEndIndex = markdown.index(after: lineEndIndex)
            }
            if lineEndIndex < end {
                // include newline; handle CRLF by including both
                let nl = markdown[lineEndIndex]
                lineEndIndex = markdown.index(after: lineEndIndex)
                if nl == "\r", lineEndIndex < end, markdown[lineEndIndex] == "\n" {
                    lineEndIndex = markdown.index(after: lineEndIndex)
                }
            }

            // Analyze the line without its trailing newline for fence opening.
            let rawLine = markdown[lineStartIndex ..< lineEndIndex]
            let lineSansNL: Substring = if rawLine.hasSuffix("\r\n") {
                rawLine.dropLast(2)
            } else if rawLine.hasSuffix("\n") || rawLine.hasSuffix("\r") {
                rawLine.dropLast(1)
            } else {
                rawLine
            }

            if let opening = parseOpeningMermaidFence(lineSansNL) {
                // Flush preceding markdown (everything before this opening line).
                flushMarkdown(upTo: lineStartIndex, endLine: lineStartLine - 1)

                // Mermaid code begins after the opening line.
                let codeStartIndex = lineEndIndex
                var searchCursor = codeStartIndex
                var searchLine = lineStartLine + 1
                var foundClose: MermaidFenceClose?

                while searchCursor < end {
                    let closeLineStartIndex = searchCursor
                    let closeLineNumber = searchLine

                    var closeLineEndIndex = searchCursor
                    while closeLineEndIndex < end, !markdown[closeLineEndIndex].isNewline {
                        closeLineEndIndex = markdown.index(after: closeLineEndIndex)
                    }
                    var closeLineEndIncludingNL = closeLineEndIndex
                    if closeLineEndIncludingNL < end {
                        let nl = markdown[closeLineEndIncludingNL]
                        closeLineEndIncludingNL = markdown.index(after: closeLineEndIncludingNL)
                        if nl == "\r", closeLineEndIncludingNL < end, markdown[closeLineEndIncludingNL] == "\n" {
                            closeLineEndIncludingNL = markdown.index(after: closeLineEndIncludingNL)
                        }
                    }

                    let rawCloseLine = markdown[closeLineStartIndex ..< closeLineEndIncludingNL]
                    let closeSansNL: Substring = if rawCloseLine.hasSuffix("\r\n") {
                        rawCloseLine.dropLast(2)
                    } else if rawCloseLine.hasSuffix("\n") || rawCloseLine.hasSuffix("\r") {
                        rawCloseLine.dropLast(1)
                    } else {
                        rawCloseLine
                    }

                    if isClosingFenceLine(closeSansNL, fenceChar: opening.fenceChar, minLength: opening.fenceLength) {
                        foundClose = MermaidFenceClose(
                            codeEnd: closeLineStartIndex,
                            afterClose: closeLineEndIncludingNL,
                            closeLine: closeLineNumber
                        )
                        break
                    }

                    searchCursor = closeLineEndIncludingNL
                    searchLine += 1
                }

                if let foundClose {
                    let code = String(markdown[codeStartIndex ..< foundClose.codeEnd])
                    blocks.append(
                        SpannedBlock(
                            id: blocks.count,
                            block: .mermaid(code),
                            startLine: lineStartLine,
                            endLine: foundClose.closeLine
                        )
                    )
                    cursor = foundClose.afterClose
                    currentLine = foundClose.closeLine + 1
                    markdownSegmentStartIndex = cursor
                    markdownSegmentStartLine = currentLine
                    continue
                } else {
                    // Unclosed fence: treat the rest of the document as Mermaid source.
                    let code = String(markdown[codeStartIndex ..< end])
                    blocks.append(
                        SpannedBlock(
                            id: blocks.count,
                            block: .mermaid(code),
                            startLine: lineStartLine,
                            endLine: lineStartLine + max(0, searchLine - (lineStartLine + 1))
                        )
                    )
                    cursor = end
                    markdownSegmentStartIndex = end
                    markdownSegmentStartLine = searchLine
                    currentLine = searchLine
                    break
                }
            }

            cursor = lineEndIndex
            currentLine += 1
        }

        flushMarkdown(upTo: end, endLine: max(markdownSegmentStartLine, currentLine - 1))
        if blocks.isEmpty {
            return [SpannedBlock(id: 0, block: .markdown(markdown), startLine: 1, endLine: max(1, currentLine - 1))]
        }
        return blocks
    }

    // MARK: - Fence parsing

    private struct OpeningFence {
        let fenceChar: Character
        let fenceLength: Int
    }

    private static func parseOpeningMermaidFence(_ line: Substring) -> OpeningFence? {
        // CommonMark: up to 3 spaces indentation.
        var idx = line.startIndex
        var spaces = 0
        while idx < line.endIndex, spaces < 3 {
            let ch = line[idx]
            if ch == " " {
                spaces += 1
                idx = line.index(after: idx)
            } else if ch == "\t" {
                // treat tab as indentation too
                idx = line.index(after: idx)
                break
            } else {
                break
            }
        }

        guard idx < line.endIndex else { return nil }
        let fenceChar = line[idx]
        guard fenceChar == "`" || fenceChar == "~" else { return nil }

        var len = 0
        while idx < line.endIndex, line[idx] == fenceChar {
            len += 1
            idx = line.index(after: idx)
        }
        guard len >= 3 else { return nil }

        // Info string is the rest of the line.
        let info = String(line[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = info.split(whereSeparator: { $0.isWhitespace }).first.map { String($0) } ?? ""
        guard firstToken.lowercased() == "mermaid" else { return nil }

        return OpeningFence(fenceChar: fenceChar, fenceLength: len)
    }

    private static func isClosingFenceLine(_ line: Substring, fenceChar: Character, minLength: Int) -> Bool {
        var idx = line.startIndex
        var spaces = 0
        while idx < line.endIndex, spaces < 3 {
            let ch = line[idx]
            if ch == " " {
                spaces += 1
                idx = line.index(after: idx)
            } else if ch == "\t" {
                idx = line.index(after: idx)
                break
            } else {
                break
            }
        }

        guard idx < line.endIndex else { return false }
        guard line[idx] == fenceChar else { return false }

        var len = 0
        while idx < line.endIndex, line[idx] == fenceChar {
            len += 1
            idx = line.index(after: idx)
        }
        guard len >= minLength else { return false }

        // The rest must be whitespace only.
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == " " || ch == "\t" {
                idx = line.index(after: idx)
                continue
            }
            return false
        }
        return true
    }
}
