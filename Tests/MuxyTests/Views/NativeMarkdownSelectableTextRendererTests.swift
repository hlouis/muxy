import AppKit
import Testing

@testable import Muxy

@Suite("NativeMarkdownSelectableTextRenderer")
struct NativeMarkdownSelectableTextRendererTests {
    private let palette = MarkdownRenderer.Palette(
        background: .white,
        foreground: .black,
        accent: .systemBlue,
        fontFamilyName: nil,
        fontScale: 1
    )

    @Test("inline code is styled as monospaced with a custom background marker")
    func inlineCodeStyling() throws {
        let attributed = try #require(NativeMarkdownSelectableTextRenderer.attributedMarkdown(
            from: "Use `let value = 1` here.",
            baseURL: nil,
            palette: palette
        ))

        let codeRange = (attributed.string as NSString).range(of: "let value = 1")
        #expect(codeRange.location != NSNotFound)
        let inlineCodeAttribute = NSAttributedString.Key("muxy.nativeMarkdown.inlineCode")
        #expect(attributed.attribute(inlineCodeAttribute, at: codeRange.location, effectiveRange: nil) != nil)
        #expect(attributed.attribute(inlineCodeAttribute, at: codeRange.location - 1, effectiveRange: nil) == nil)
        #expect(attributed.attribute(inlineCodeAttribute, at: NSMaxRange(codeRange), effectiveRange: nil) == nil)

        let font = try #require(attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
    }

    @Test("fenced code blocks are monospaced and tagged for full block background drawing")
    func fencedCodeBlockStyling() throws {
        let attributed = try #require(NativeMarkdownSelectableTextRenderer.attributedMarkdown(
            from: """
            Before

            ```swift
            let value = 1
            print(value)
            ```

            After
            """,
            baseURL: nil,
            palette: palette
        ))

        let codeRange = (attributed.string as NSString).range(of: "let value = 1")
        #expect(codeRange.location != NSNotFound)
        #expect(attributed.attribute(NSAttributedString.Key("muxy.nativeMarkdown.codeBlock"), at: codeRange.location, effectiveRange: nil) != nil)

        let font = try #require(attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
    }

    @Test("requested text alignment is applied to rendered paragraphs")
    func paragraphAlignment() throws {
        let attributed = try #require(NativeMarkdownSelectableTextRenderer.attributedMarkdown(
            from: "Centered `code` text.",
            baseURL: nil,
            palette: palette,
            textAlignment: .center
        ))

        let paragraphStyle = try #require(attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraphStyle.alignment == .center)
    }

    @Test("pipe markdown tables are split into table segments")
    func pipeTableSegments() throws {
        let segments = NativeMarkdownTableParser.segments(from: """
        Intro

        | Method | Path | Purpose |
        | ------ | :--- | ------: |
        | `GET` | `/items` | List items |
        | `POST` | `/items` | Create item |

        Outro
        """)

        #expect(segments.count == 3)
        let segmentIDs = segments.map(\.id)
        #expect(Set(segmentIDs).count == segmentIDs.count)
        guard case .markdown = segments[0] else {
            Issue.record("Expected leading markdown segment")
            return
        }
        guard case let .table(table) = segments[1] else {
            Issue.record("Expected table segment")
            return
        }
        guard case .markdown = segments[2] else {
            Issue.record("Expected trailing markdown segment")
            return
        }

        #expect(table.headers == ["Method", "Path", "Purpose"])
        #expect(table.alignments == [.leading, .leading, .trailing])
        #expect(table.rows == [
            ["`GET`", "`/items`", "List items"],
            ["`POST`", "`/items`", "Create item"],
        ])
    }
}
