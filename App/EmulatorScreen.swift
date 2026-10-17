import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit

final class EmulatorScreenView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.magnificationFilter = .nearest
        layer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct EmulatorScreen: UIViewRepresentable {
    let session: GameSession

    func makeUIView(context: Context) -> EmulatorScreenView {
        let view = EmulatorScreenView()
        session.displayLayer = view.layer
        return view
    }

    func updateUIView(_ view: EmulatorScreenView, context: Context) {}
}
#else
import AppKit

final class EmulatorScreenView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    private var screenObserver: NSObjectProtocol?
    private var observedWindowID: ObjectIdentifier?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservation()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.magnificationFilter = .nearest
        layer.contentsGravity = .resizeAspect
        self.layer = layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateWindowObservation() {
        let currentWindow = window
        let currentWindowID = currentWindow.map { ObjectIdentifier($0) }
        guard currentWindowID != observedWindowID else { return }
        removeScreenObserver()
        observedWindowID = currentWindowID
        onWindowChange?(currentWindow)
        guard let currentWindow else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: currentWindow,
            queue: .main
        ) { [weak self, weak currentWindow] _ in
            MainActor.assumeIsolated {
                self?.onWindowChange?(currentWindow)
            }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }
}

struct EmulatorScreen: NSViewRepresentable {
    let session: GameSession

    func makeNSView(context: Context) -> EmulatorScreenView {
        let view = EmulatorScreenView()
        session.displayLayer = view.layer
        let input = session.input
        view.onWindowChange = { window in
            input.window = window
            session.setPresentationScreen(window?.screen)
        }
        return view
    }

    func updateNSView(_ view: EmulatorScreenView, context: Context) {}
}
#endif
