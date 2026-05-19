import AppKit
import SwiftUI

#if canImport(BeautifulMermaid)
import BeautifulMermaid

@available(macOS 14.0, *)
struct NativeMermaidBlockView: View {
    let source: String
    let palette: MarkdownRenderer.Palette
    let refreshVersion: Int

    @State private var parseError: Error?
    @State private var diagramBounds: CGRect = .zero
    @State private var availableWidth: CGFloat = 0
    @State private var exportError: String?

    private var theme: DiagramTheme {
        DiagramTheme(
            background: palette.background,
            foreground: palette.foreground,
            accent: palette.accent
        )
    }

    private var layoutConfig: BeautifulMermaid.LayoutConfig {
        BeautifulMermaid.LayoutConfig(padding: 24, nodeSpacing: 28, layerSpacing: 48, componentSpacing: 20)
    }

    private var fittedDiagramHeight: CGFloat {
        let fallback: CGFloat = 240
        guard availableWidth > 0, diagramBounds.width > 0, diagramBounds.height > 0 else { return fallback }
        return max(120, availableWidth * diagramBounds.height / diagramBounds.width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Mermaid")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: palette.foreground).opacity(0.68))
                Spacer()
                NativeMermaidPreviewButton(
                    title: "Open in Preview",
                    systemImageName: "arrow.up.right.square",
                    enabled: !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    openDiagramInPreview()
                }
            }

            ZStack {
                Color(nsColor: palette.background)

                if parseError == nil {
                    MermaidDiagramRepresentable(
                        source: source,
                        theme: theme,
                        layoutConfig: layoutConfig,
                        refreshVersion: refreshVersion,
                        diagramBounds: $diagramBounds,
                        parseError: $parseError
                    )
                    .frame(width: max(1, availableWidth), height: fittedDiagramHeight)
                }
            }
            .frame(width: max(1, availableWidth), height: fittedDiagramHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        Color(nsColor: blend(foreground: palette.foreground, background: palette.background, amount: 0.2)),
                        lineWidth: 1
                    )
            )

            if let parseError {
                MermaidErrorBlockView(title: "Mermaid error", message: parseError.localizedDescription, palette: palette)
            }

            if let exportError {
                MermaidErrorBlockView(title: "Preview export error", message: exportError, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateAvailableWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in updateAvailableWidth(width) }
            }
        )
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        availableWidth = max(0, floor(width))
    }

    private func openDiagramInPreview() {
        exportError = nil
        do {
            guard let data = try exportPNGData() else {
                exportError = "BeautifulMermaid did not produce PNG data."
                return
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MuxyMermaidPreviews", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory
                .appendingPathComponent("mermaid-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try data.write(to: fileURL, options: .atomic)

            openPNGInPreview(fileURL)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportPNGData() throws -> Data? {
        let exportLayer = MermaidLayer()
        exportLayer.theme = theme
        exportLayer.layoutConfig = layoutConfig
        exportLayer.source = source
        guard let image = exportLayer.renderImage(scale: 2.0) else { return nil }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func openPNGInPreview(_ fileURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Preview", fileURL.path]
        do {
            try process.run()
            return
        } catch {}

        if let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([fileURL], withApplicationAt: previewURL, configuration: configuration) { _, error in
                if let error {
                    DispatchQueue.main.async {
                        self.exportError = "Could not open Preview: \(error.localizedDescription). PNG written to \(fileURL.path)."
                    }
                }
            }
            return
        }

        let didOpen = NSWorkspace.shared.open(fileURL)
        if !didOpen {
            exportError = "Could not open the exported diagram. The PNG was written to \(fileURL.path)."
        }
    }
}

@available(macOS 14.0, *)
private struct MermaidDiagramRepresentable: NSViewRepresentable {
    let source: String
    let theme: DiagramTheme
    let layoutConfig: BeautifulMermaid.LayoutConfig
    let refreshVersion: Int
    @Binding var diagramBounds: CGRect
    @Binding var parseError: Error?

    func makeNSView(context: Context) -> NativeMermaidZoomScrollView {
        let diagramView = MermaidView()
        diagramView.theme = theme
        diagramView.layoutConfig = layoutConfig
        diagramView.mermaidLayer.onPrepareComplete = { [weak diagramView] in
            guard let diagramView else { return }
            publish(from: diagramView)
        }
        diagramView.source = source

        let scrollView = NativeMermaidZoomScrollView()
        scrollView.documentView = diagramView
        scrollView.diagramView = diagramView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 6.0
        scrollView.magnification = 1.0

        publish(from: diagramView)
        return scrollView
    }

    func updateNSView(_ scrollView: NativeMermaidZoomScrollView, context: Context) {
        guard let diagramView = scrollView.diagramView else { return }
        diagramView.theme = theme
        diagramView.layoutConfig = layoutConfig
        if diagramView.source != source {
            scrollView.magnification = 1.0
            diagramView.source = source
        } else {
            diagramView.needsDisplay = true
        }
        sizeDocumentToViewport(scrollView)
        publish(from: diagramView)
    }

    private func sizeDocumentToViewport(_ scrollView: NSScrollView) {
        let viewportSize = scrollView.contentView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        scrollView.documentView?.frame = NSRect(origin: .zero, size: viewportSize)
    }

    private func publish(from view: MermaidView) {
        let bounds = view.diagramBounds
        let error = view.parseError
        DispatchQueue.main.async {
            if diagramBounds != bounds { diagramBounds = bounds }
            if !errorsEqual(parseError, error) { parseError = error }
        }
    }

    private func errorsEqual(_ lhs: Error?, _ rhs: Error?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (l?, r?): l.localizedDescription == r.localizedDescription
        default: false
        }
    }
}

@available(macOS 14.0, *)
final class NativeMermaidZoomScrollView: NSScrollView {
    weak var diagramView: MermaidView?

    override func layout() {
        super.layout()
        let viewport = contentView.bounds.size
        guard let documentView, viewport.width > 0, viewport.height > 0 else { return }
        let unscaledSize = NSSize(width: viewport.width / magnification, height: viewport.height / magnification)
        if documentView.frame.size != unscaledSize {
            documentView.frame = NSRect(origin: .zero, size: unscaledSize)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let canScrollHorizontally = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if magnification <= minMagnification, !canScrollHorizontally, !event.modifierFlags.contains(.command) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

private struct NativeMermaidPreviewButton: NSViewRepresentable {
    let title: String
    let systemImageName: String
    let enabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NativeMermaidPreviewNSButton {
        let button = NativeMermaidPreviewNSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        configure(button)
        return button
    }

    func updateNSView(_ button: NativeMermaidPreviewNSButton, context: Context) {
        context.coordinator.action = action
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        configure(button)
    }

    private func configure(_ button: NativeMermaidPreviewNSButton) {
        button.title = title
        button.image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .controlAccentColor
        button.isEnabled = enabled
        button.wantsPointingHandCursor = enabled
        button.sizeToFit()
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc
        func performAction() {
            action()
        }
    }
}

final class NativeMermaidPreviewNSButton: NSButton {
    var wantsPointingHandCursor = true

    override func resetCursorRects() {}

    override func cursorUpdate(with event: NSEvent) {}
}

@available(macOS 14.0, *)
private struct MermaidErrorBlockView: View {
    let title: String
    let message: String
    let palette: MarkdownRenderer.Palette

    private var errorForeground: NSColor { .systemRed }
    private var errorBackground: NSColor {
        blend(foreground: errorForeground, background: palette.background, amount: 0.12)
    }

    private var errorBorder: NSColor {
        blend(foreground: errorForeground, background: palette.background, amount: 0.35)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: errorForeground))

            Text(message)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(nsColor: errorForeground))
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: errorBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: errorBorder), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private func blend(foreground: NSColor, background: NSColor, amount: CGFloat) -> NSColor {
    let fg = (foreground.usingColorSpace(.deviceRGB) ?? foreground)
    let bg = (background.usingColorSpace(.deviceRGB) ?? background)

    let clamped = min(max(amount, 0), 1)

    let r = bg.redComponent + (fg.redComponent - bg.redComponent) * clamped
    let g = bg.greenComponent + (fg.greenComponent - bg.greenComponent) * clamped
    let b = bg.blueComponent + (fg.blueComponent - bg.blueComponent) * clamped
    let a = bg.alphaComponent + (fg.alphaComponent - bg.alphaComponent) * clamped

    return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

#endif
