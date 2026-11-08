import AppKit
import SwiftUI

// The same handle Distil uses beside its sidebar; each product keeps its own copy so both stay
// independently buildable.

/// Drag to resize the sidebar. Also adjustable with VoiceOver (increment/decrement).
struct SidebarResizeHandle: View {
    static let thickness: CGFloat = 5
    @Binding var width: Double
    let range: ClosedRange<CGFloat>
    @State private var dragStart: Double?
    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Self.thickness)
            .frame(maxHeight: .infinity)
            .overlay(Rectangle().fill(DS.accent.opacity(hovering || dragStart != nil ? 0.45 : 0.16)).frame(width: 1))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                updateCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? width
                        dragStart = start
                        width = clamp(start + Double(value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil; updateCursor() }
            )
            .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = clamp(width + 10)
                case .decrement: width = clamp(width - 10)
                @unknown default: break
                }
            }
            .help("Drag to resize the sidebar")
    }

    /// Keep the resize cursor while hovering or dragging; push and pop stay balanced.
    private func updateCursor() {
        let wanted = hovering || dragStart != nil
        if wanted && !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
        if !wanted && cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, Double(range.lowerBound)), Double(range.upperBound))
    }
}
