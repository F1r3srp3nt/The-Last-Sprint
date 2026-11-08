import SwiftUI
import AppKit

/// Routes the window's close button through the unsaved-changes prompt and keeps the
/// close button's "edited" dot in sync. ⌘W is routed the same way from the File menu.
/// If this hook ever fails to install, closing still cannot lose work silently: quitting
/// prompts in `applicationShouldTerminate`, and the project stays in memory until then.
struct WindowCloseGuard: NSViewRepresentable {
    let isEdited: Bool
    let onCloseRequest: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        context.coordinator.onCloseRequest = onCloseRequest
        context.coordinator.isEdited = isEdited
        context.coordinator.install(on: view.window)
    }

    final class Coordinator: NSObject {
        var onCloseRequest: ((NSWindow) -> Void)?
        var isEdited = false { didSet { window?.isDocumentEdited = isEdited } }
        private weak var window: NSWindow?

        func install(on window: NSWindow?) {
            guard let window else { return }
            window.isDocumentEdited = isEdited
            guard window !== self.window else { return }
            self.window = window
            if let button = window.standardWindowButton(.closeButton) {
                button.target = self
                button.action = #selector(closeButtonPressed(_:))
            }
        }

        @objc func closeButtonPressed(_ sender: Any?) {
            guard let window else { return }
            onCloseRequest?(window)
        }
    }

    final class GuardView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.install(on: window)
        }
    }
}
