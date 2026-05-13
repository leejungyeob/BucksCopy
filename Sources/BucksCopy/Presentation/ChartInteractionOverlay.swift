import AppKit
import SwiftUI

struct ChartPointerDrag {
    let startLocation: CGPoint
    let location: CGPoint
    let translation: CGSize
}

struct ChartScrollEvent {
    let location: CGPoint
    let deltaX: CGFloat
    let deltaY: CGFloat
    let hasPreciseDeltas: Bool
}

struct ChartMagnifyEvent {
    let location: CGPoint
    let magnification: CGFloat
}

struct ChartInteractionOverlay: NSViewRepresentable {
    let onDragChanged: (ChartPointerDrag) -> Void
    let onDragEnded: (ChartPointerDrag) -> Void
    let onScroll: (ChartScrollEvent) -> Void
    let onMagnify: (ChartMagnifyEvent) -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
    }

    final class InteractionView: NSView {
        var onDragChanged: ((ChartPointerDrag) -> Void)?
        var onDragEnded: ((ChartPointerDrag) -> Void)?
        var onScroll: ((ChartScrollEvent) -> Void)?
        var onMagnify: ((ChartMagnifyEvent) -> Void)?

        private var dragStart: CGPoint?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            dragStart = location(from: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            onDragChanged?(drag(from: dragStart, event: event))
        }

        override func mouseUp(with event: NSEvent) {
            guard let dragStart else { return }
            onDragEnded?(drag(from: dragStart, event: event))
            self.dragStart = nil
        }

        override func scrollWheel(with event: NSEvent) {
            onScroll?(ChartScrollEvent(
                location: location(from: event),
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas
            ))
        }

        override func magnify(with event: NSEvent) {
            onMagnify?(ChartMagnifyEvent(
                location: location(from: event),
                magnification: event.magnification
            ))
        }

        private func drag(from startLocation: CGPoint, event: NSEvent) -> ChartPointerDrag {
            let location = location(from: event)
            return ChartPointerDrag(
                startLocation: startLocation,
                location: location,
                translation: CGSize(
                    width: location.x - startLocation.x,
                    height: location.y - startLocation.y
                )
            )
        }

        private func location(from event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }
    }
}
