import CoreGraphics

struct MarkdownPreviewScrollReport: Equatable {
    let scrollTop: CGFloat
    let scrollHeight: CGFloat
    let clientHeight: CGFloat

    var maxScrollTop: CGFloat { max(0, scrollHeight - clientHeight) }
}
