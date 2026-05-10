# BeautifulMermaid Swift integration notes (Muxy native Markdown preview)

This repo currently does **not** include BeautifulMermaid in `Package.swift` (as of 2026-05-05). Below are the exact API surface findings and a minimal macOS SwiftUI integration prototype that should compile once the dependency is added.

## Upstream package

- Repo: https://github.com/lukilabs/beautiful-mermaid-swift
- Product (SPM): `BeautifulMermaid`
- Target module to import: `BeautifulMermaid`
- Upstream target name is `BeautifulMermaid` with sources under `Sources/BeautifulMermaidSwift/`.

### SPM additions (Muxy)

Add the package:

```swift
// Package.swift
dependencies: [
  // ...
  .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", from: "1.0.0"),
]
```

Add product to the app target dependencies (likely the `Muxy` executable target):

```swift
.executableTarget(
  name: "Muxy",
  dependencies: [
    // ...
    .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
  ]
)
```

Upstream depends on `elk-swift` transitively.

## API reality check vs README

The upstream README examples match the actual public API:

- `import BeautifulMermaid`
- `MermaidRenderer.renderImage(source:theme:scale:)` (throws)
- `MermaidRenderer.renderSVG(source:theme:)` (throws)
- `MermaidRenderer.renderASCII(source:theme:)` (throws)
- SwiftUI: `MermaidDiagramView(source:theme:layoutConfig:parseError:diagramBounds:)`
- AppKit: `MermaidView: NSView` with `source`, `theme`, `layoutConfig`, `parseError`, `diagramBounds`

## Minimal SwiftUI Mermaid block view (macOS)

Upstream provides a SwiftUI wrapper type that uses `NSViewRepresentable` on macOS.

```swift
import SwiftUI
import BeautifulMermaid

@available(macOS 13.0, *)
struct NativeMermaidBlockView: View {
    let source: String
    let theme: DiagramTheme

    @State private var parseError: Error?
    @State private var diagramBounds: CGRect = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MermaidDiagramView(
                source: source,
                theme: theme,
                layoutConfig: LayoutConfig(),
                parseError: $parseError,
                diagramBounds: $diagramBounds
            )
            // The underlying MermaidView draws by fitting the diagram into its bounds.
            // If you want it to size-to-content, use diagramBounds once non-zero.
            .frame(
                minHeight: 120,
                idealHeight: diagramBounds.height > 0 ? diagramBounds.height : 240
            )

            if let parseError {
                // Upstream sets `parseError` when parse/layout fails.
                Text("Mermaid error: \(parseError.localizedDescription)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
```

Notes:

- `MermaidDiagramView` is `@available(macOS 13.0, *)`.
- `LayoutConfig()` is a value type (declared upstream) that controls padding/spacing.
- Error reporting is via the `parseError` binding and/or `MermaidView.parseError`.

## Theme mapping (Muxy palette -> BeautifulMermaid DiagramTheme)

Upstream uses a cross-platform `BMColor` typealias:

- macOS: `typealias BMColor = NSColor`
- iOS: `typealias BMColor = UIColor`

So on macOS you can pass `NSColor` values directly into `DiagramTheme`.

### Minimal mapping using Muxy’s `EditorThemePalette`

Muxy already has `EditorThemePalette.active` as `NSColor` values.

```swift
import AppKit
import BeautifulMermaid

@MainActor
func makeMermaidThemeFromMuxyPalette() -> DiagramTheme {
    let p = EditorThemePalette.active

    // BeautifulMermaid only requires background+foreground.
    // Everything else is derived via fixed blend ratios.
    return DiagramTheme(
        background: p.background,
        foreground: p.foreground,
        accent: p.accent
        // Optionally provide line/muted/surface/border overrides if desired.
    )
}
```

### Hex-based mapping (when you only have strings)

Upstream provides `BMColor(hex:)` and `BMColor.hexString` in `CrossPlatform.swift`.

```swift
import BeautifulMermaid

let theme = DiagramTheme(
    background: BMColor(hex: "#1a1b26"),
    foreground: BMColor(hex: "#c0caf5")
)
```

Muxy already has a `colorToHex(_:)` helper in `Muxy/Models/MarkdownRenderer.swift` (returns `RRGGBB` without the `#`). You can reuse that approach if you need deterministic hex output.

## Error handling patterns

There are three common ways to handle errors:

1. **SwiftUI binding**: pass `parseError: Binding<Error?>` into `MermaidDiagramView` and render an inline error view when non-nil.
2. **NSView subclass**: use `MermaidView.parseError` and update UI accordingly.
3. **Pure rendering API**: call `MermaidRenderer.parse(_:)` or `MermaidRenderer.layout(_:)` in a `do/catch` to surface parse/layout failures.

Upstream behavior:

- `MermaidLayer.prepareDiagram()` sets `parseError = error` on any parse/layout/render prep failure.
- Empty source clears `parseError` and results in no prepared diagram.

## Rendering details (important for AppKit)

If Muxy chooses to bypass `MermaidView`/`MermaidDiagramView` and render directly into a `CGContext` using:

```swift
try MermaidRenderer.render(source:in:bounds:theme:)
```

Upstream documents a coordinate-system requirement:

- `DiagramRenderer` expects a **top-left origin** (y=0 at top).
- AppKit `CGContext`s are typically **bottom-left origin**.

So for raw AppKit contexts you must flip before rendering:

```swift
ctx.translateBy(x: 0, y: bounds.height)
ctx.scaleBy(x: 1, y: -1)
```

`MermaidView.draw(_:)` already performs this flip internally.

## Practical recommendation for Muxy native Markdown preview

- Prefer `MermaidDiagramView` for quickest SwiftUI integration.
- Use `EditorThemePalette.active` to create `DiagramTheme` (pass NSColors directly).
- Use the `parseError` binding to show an inline error box similar to the current WebView-based Mermaid error output.
- Consider caching rendered images or prepared diagrams (`PreparedDiagram`) if performance becomes an issue in large documents.
