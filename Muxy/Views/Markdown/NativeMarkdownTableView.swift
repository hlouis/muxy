import AppKit
import SwiftUI

enum NativeMarkdownTableParser {
    struct Table: Equatable, Identifiable {
        enum ColumnAlignment: Equatable {
            case leading
            case center
            case trailing

            var frameAlignment: Alignment {
                switch self {
                case .leading: .leading
                case .center: .center
                case .trailing: .trailing
                }
            }

            var textAlignment: TextAlignment {
                switch self {
                case .leading: .leading
                case .center: .center
                case .trailing: .trailing
                }
            }
        }

        let id: Int
        let headers: [String]
        let alignments: [ColumnAlignment]
        let rows: [[String]]

        func withID(_ id: Int) -> Table {
            Table(id: id, headers: headers, alignments: alignments, rows: rows)
        }

        var columnCount: Int { headers.count }
    }

    enum Segment: Equatable, Identifiable {
        case markdown(id: Int, String)
        case table(Table)

        var id: Int {
            switch self {
            case let .markdown(id, _): id
            case let .table(table): table.id
            }
        }
    }

    static func segments(from markdown: String) -> [Segment] {
        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedMarkdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var segments: [Segment] = []
        var markdownBuffer: [String] = []
        var index = 0

        func flushMarkdown() {
            let text = markdownBuffer.joined(separator: "\n")
            markdownBuffer.removeAll(keepingCapacity: true)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments.append(.markdown(id: segments.count, text))
        }

        while index < lines.count {
            if let parsedTable = parseTable(in: lines, startingAt: index) {
                flushMarkdown()
                segments.append(.table(parsedTable.table.withID(segments.count)))
                index = parsedTable.nextIndex
                continue
            }

            markdownBuffer.append(lines[index])
            index += 1
        }

        flushMarkdown()
        return segments.isEmpty ? [.markdown(id: 0, markdown)] : segments
    }

    static func parseTable(from markdown: String) -> Table? {
        segments(from: markdown).compactMap { segment in
            if case let .table(table) = segment { return table }
            return nil
        }.first
    }

    private static func parseTable(in lines: [String], startingAt index: Int) -> (table: Table, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headerCells = parseContentRow(lines[index]),
              headerCells.count >= 2,
              let alignments = parseDelimiterRow(lines[index + 1]),
              alignments.count == headerCells.count
        else { return nil }

        var rows: [[String]] = []
        var scanIndex = index + 2
        while scanIndex < lines.count, let row = parseContentRow(lines[scanIndex]) {
            rows.append(normalizedRow(row, columnCount: headerCells.count))
            scanIndex += 1
        }

        return (
            Table(
                id: 0,
                headers: normalizedRow(headerCells, columnCount: headerCells.count),
                alignments: alignments,
                rows: rows
            ),
            scanIndex
        )
    }

    private static func parseContentRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return nil }
        let cells = splitPipeCells(trimmed)
        guard cells.count >= 2 else { return nil }
        return cells
    }

    private static func parseDelimiterRow(_ line: String) -> [Table.ColumnAlignment]? {
        guard let cells = parseContentRow(line) else { return nil }
        var alignments: [Table.ColumnAlignment] = []
        alignments.reserveCapacity(cells.count)

        for cell in cells {
            let marker = cell.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
            guard marker.count(where: { $0 == "-" }) >= 3,
                  marker.allSatisfy({ $0 == "-" || $0 == ":" })
            else { return nil }

            if marker.hasPrefix(":"), marker.hasSuffix(":") {
                alignments.append(.center)
            } else if marker.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }

        return alignments
    }

    private static func splitPipeCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "|" { text.removeFirst() }
        if text.last == "|" { text.removeLast() }

        var cells: [String] = []
        var current = ""
        var isEscaped = false

        for character in text {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }

        if isEscaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return cells
    }

    private static func normalizedRow(_ row: [String], columnCount: Int) -> [String] {
        if row.count == columnCount { return row }
        if row.count > columnCount { return Array(row.prefix(columnCount)) }
        return row + Array(repeating: "", count: columnCount - row.count)
    }
}

struct NativeMarkdownFlowContentView: View {
    let markdown: String
    let baseURL: URL?
    let palette: MarkdownRenderer.Palette
    var textAlignment: NSTextAlignment = .natural

    private var segments: [NativeMarkdownTableParser.Segment] {
        NativeMarkdownTableParser.segments(from: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment {
                case let .markdown(_, markdown):
                    if let attributedMarkdown = NativeMarkdownSelectableTextRenderer.attributedMarkdown(
                        from: markdown,
                        baseURL: baseURL,
                        palette: palette,
                        textAlignment: textAlignment
                    ) {
                        NativeMarkdownSelectableTextBlockView(attributedString: attributedMarkdown, palette: palette)
                            .frame(maxWidth: .infinity, alignment: textAlignment.frameAlignment)
                    }

                case let .table(table):
                    NativeMarkdownTableView(table: table, baseURL: baseURL, palette: palette)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct NativeMarkdownTableView: View {
    let table: NativeMarkdownTableParser.Table
    let baseURL: URL?
    let palette: MarkdownRenderer.Palette

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0 ..< table.columnCount, id: \.self) { column in
                    cell(table.headers[column], column: column, isHeader: true)
                }
            }

            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0 ..< table.columnCount, id: \.self) { column in
                        cell(row[safe: column] ?? "", column: column, isHeader: false)
                    }
                }
            }
        }
        .background(Color(nsColor: palette.background))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: palette.borderColor), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ markdown: String, column: Int, isHeader: Bool) -> some View {
        NativeMarkdownTableCellText(
            markdown: markdown,
            baseURL: baseURL,
            palette: palette,
            isHeader: isHeader,
            alignment: table.alignments[safe: column] ?? .leading
        )
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(
            maxWidth: .infinity,
            minHeight: 30,
            alignment: (table.alignments[safe: column] ?? .leading).frameAlignment
        )
        .background(isHeader ? Color(nsColor: palette.codeBackgroundColor) : Color(nsColor: palette.background))
        .overlay(
            Rectangle()
                .stroke(Color(nsColor: palette.borderColor), lineWidth: 0.5)
        )
    }
}

private struct NativeMarkdownTableCellText: View {
    let markdown: String
    let baseURL: URL?
    let palette: MarkdownRenderer.Palette
    let isHeader: Bool
    let alignment: NativeMarkdownTableParser.Table.ColumnAlignment

    var body: some View {
        Text(attributedText)
            .font(.system(size: 13, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(Color(nsColor: palette.foreground))
            .multilineTextAlignment(alignment.textAlignment)
            .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
            .textSelection(.enabled)
    }

    private var attributedText: AttributedString {
        do {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return try AttributedString(markdown: markdown, options: options, baseURL: baseURL)
        } catch {
            return AttributedString(markdown)
        }
    }
}

private extension NSTextAlignment {
    var frameAlignment: Alignment {
        switch self {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
