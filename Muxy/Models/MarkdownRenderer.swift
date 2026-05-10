import AppKit

/// Shared palette values for the native Markdown preview and embedded block renderers.
enum MarkdownRenderer {
    struct Palette: Equatable {
        let background: NSColor
        let foreground: NSColor
        let accent: NSColor
        let fontFamilyCSS: String
        let fontScale: CGFloat
    }
}
