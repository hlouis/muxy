import Testing

@testable import Muxy

@Suite("NativeMarkdownDocumentParser")
struct NativeMarkdownDocumentParserTests {
    @Test("parse returns single markdown block when no mermaid fences")
    func noMermaid() {
        let input = "# Title\n\nHello\n"
        let blocks = NativeMarkdownDocumentParser.parse(input)
        #expect(blocks == [.markdown(input)])
    }

    @Test("parse extracts backtick fenced mermaid blocks")
    func extractsBacktickMermaid() {
        let input = """
        Before

        ```mermaid
        graph TD
        A-->B
        ```

        After
        """

        let blocks = NativeMarkdownDocumentParser.parse(input)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .markdown("Before\n\n"))
        #expect(blocks[1] == .mermaid("graph TD\nA-->B\n"))
        #expect(blocks[2] == .markdown("\nAfter"))
    }

    @Test("parse extracts tilde fenced mermaid blocks")
    func extractsTildeMermaid() {
        let input = """
        x
        ~~~mermaid
        graph LR
        A-->B
        ~~~
        y
        """
        let blocks = NativeMarkdownDocumentParser.parse(input)
        #expect(blocks == [.markdown("x\n"), .mermaid("graph LR\nA-->B\n"), .markdown("y")])
    }

    @Test("parse is case-insensitive for the mermaid info token")
    func mermaidTokenCaseInsensitive() {
        let input = """
        ```MeRmAiD
        graph TD
        A-->B
        ```
        """
        let blocks = NativeMarkdownDocumentParser.parse(input)
        #expect(blocks == [.mermaid("graph TD\nA-->B\n")])
    }

    @Test("parse supports fence length >= 3 and closing fence length >= opening")
    func fenceLengths() {
        let input = """
        ````mermaid
        graph TD
        A-->B
        ``````
        """
        let blocks = NativeMarkdownDocumentParser.parse(input)
        #expect(blocks == [.mermaid("graph TD\nA-->B\n")])
    }

    @Test("parse extracts multiple mermaid blocks")
    func multipleBlocks() {
        let input = """
        a
        ```mermaid
        A-->B
        ```
        b
        ~~~mermaid
        C-->D
        ~~~
        c
        """
        let blocks = NativeMarkdownDocumentParser.parse(input)
        #expect(blocks == [
            .markdown("a\n"),
            .mermaid("A-->B\n"),
            .markdown("b\n"),
            .mermaid("C-->D\n"),
            .markdown("c")
        ])
    }

    @Test("parse leaves non-mermaid fenced blocks inside markdown")
    func nonMermaidFencesPreserved() {
        let input = """
        ```swift
        print(\"hi\")
        ```
        """
        let blocks = NativeMarkdownDocumentParser.parse(input)
        #expect(blocks == [.markdown(input)])
    }

    @Test("parse handles unclosed mermaid fence by treating rest of document as mermaid")
    func unclosedFence() {
        let input = """
        pre
        ```mermaid
        graph TD
        A-->B
        """
        let blocks = NativeMarkdownDocumentParser.parse(input)
        #expect(blocks == [.markdown("pre\n"), .mermaid("graph TD\nA-->B")])
    }
}
