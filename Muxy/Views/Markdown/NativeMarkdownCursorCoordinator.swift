import AppKit

@MainActor
final class NativeMarkdownCursorCoordinator {
    static let shared = NativeMarkdownCursorCoordinator()

    private var scrollViewBoxes: [WeakScrollViewBox] = []
    private var localEventMonitor: Any?

    private init() {}

    func attach(_ scrollView: NSScrollView) {
        scrollView.window?.acceptsMouseMovedEvents = true
        scrollViewBoxes.removeAll { $0.value == nil || $0.value === scrollView }
        scrollViewBoxes.append(WeakScrollViewBox(scrollView))
        ensureEventMonitor()
    }

    func detach(_ scrollView: NSScrollView) {
        scrollView.nativeMarkdownClearLinkHovers(except: nil)
        scrollViewBoxes.removeAll { $0.value == nil || $0.value === scrollView }
        if scrollViewBoxes.isEmpty, let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    func scheduleUpdateAfterScroll(for scrollView: NSScrollView) {
        guard let window = scrollView.window else { return }
        applyCursor(forWindowPoint: window.mouseLocationOutsideOfEventStream)

        let visibleWindowRect = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
        let rootView = scrollView.documentView ?? scrollView
        rootView.nativeMarkdownRefreshHoverState(inVisibleWindowRect: visibleWindowRect, window: window)
    }

    private func ensureEventMonitor() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]
        ) { [weak self] event in
            self?.applyCursor(forWindowPoint: event.locationInWindow)
            return event
        }
    }

    private func applyCursor(forWindowPoint windowPoint: NSPoint) {
        var visitedWindows: Set<ObjectIdentifier> = []
        for box in scrollViewBoxes {
            guard let scrollView = box.value, let window = scrollView.window, window.isVisible else { continue }
            guard visitedWindows.insert(ObjectIdentifier(window)).inserted else { continue }
            guard let contentView = window.contentView, let hitView = contentView.hitTest(windowPoint) else { continue }
            if let cursor = cursor(forHitView: hitView, windowPoint: windowPoint) {
                cursor.set()
                return
            }
        }
    }

    private func cursor(forHitView hitView: NSView, windowPoint: NSPoint) -> NSCursor? {
        var current: NSView? = hitView
        while let view = current {
            if let button = view as? NativeMermaidPreviewNSButton {
                return button.wantsPointingHandCursor ? .pointingHand : nil
            }
            if let textView = view as? NativeMarkdownSelectableTextView {
                if textView.nativeMarkdownLinkRange(atWindowPoint: windowPoint) != nil {
                    return .pointingHand
                }
                return .iBeam
            }
            current = view.superview
        }
        return nil
    }
}

private final class WeakScrollViewBox {
    weak var value: NSScrollView?

    init(_ value: NSScrollView) {
        self.value = value
    }
}

extension NSView {
    func nativeMarkdownClearLinkHovers(except retainedTextView: NativeMarkdownSelectableTextView?) {
        if let textView = self as? NativeMarkdownSelectableTextView, textView !== retainedTextView {
            textView.nativeMarkdownSetHoveredLinkRange(nil)
        }

        for subview in subviews {
            subview.nativeMarkdownClearLinkHovers(except: retainedTextView)
        }
    }

    fileprivate func nativeMarkdownRefreshHoverState(inVisibleWindowRect visibleWindowRect: NSRect, window: NSWindow) {
        if let textView = self as? NativeMarkdownSelectableTextView, textView.window === window {
            let textViewWindowRect = textView.convert(textView.bounds, to: nil)
            if textViewWindowRect.intersects(visibleWindowRect) {
                textView.nativeMarkdownRefreshLinkInteractionForCurrentMouseLocation()
            } else {
                textView.nativeMarkdownSetHoveredLinkRange(nil)
            }
        }

        for subview in subviews {
            subview.nativeMarkdownRefreshHoverState(inVisibleWindowRect: visibleWindowRect, window: window)
        }
    }
}
