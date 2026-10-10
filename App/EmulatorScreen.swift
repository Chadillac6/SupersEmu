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
}

struct EmulatorScreen: NSViewRepresentable {
    let session: GameSession

    func makeNSView(context: Context) -> EmulatorScreenView {
        let view = EmulatorScreenView()
        session.displayLayer = view.layer
        return view
    }

    func updateNSView(_ view: EmulatorScreenView, context: Context) {}
}
#endif
