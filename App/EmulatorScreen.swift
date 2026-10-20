import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit

final class EmulatorScreenView: UIView {
    let scanlines = ScanlineLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.magnificationFilter = .nearest
        layer.contentsGravity = .resizeAspect
        layer.addSublayer(scanlines)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scanlines.fit(in: bounds)
    }
}

struct EmulatorScreen: UIViewRepresentable {
    let session: GameSession

    @AppStorage(N64Graphics.Key.screenLook) private var screenLook = N64Graphics.defaultScreenLook.rawValue

    func makeUIView(context: Context) -> EmulatorScreenView {
        let view = EmulatorScreenView()
        session.displayLayer = view.layer
        return view
    }

    func updateUIView(_ view: EmulatorScreenView, context: Context) {
        view.layer.apply(screenLook: session.screenLook(screenLook), scanlines: view.scanlines,
                         aspectRatio: session.displayAspectRatio)
        view.setNeedsLayout()
    }
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
        layer.addSublayer(scanlines)
        self.layer = layer
        wantsLayer = true
    }

    let scanlines = ScanlineLayer()

    override func layout() {
        super.layout()
        scanlines.fit(in: bounds)
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
    @AppStorage(N64Graphics.Key.screenLook) private var screenLook = N64Graphics.defaultScreenLook.rawValue

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

    func updateNSView(_ view: EmulatorScreenView, context: Context) {
        view.layer?.apply(screenLook: session.screenLook(screenLook), scanlines: view.scanlines,
                          aspectRatio: session.displayAspectRatio)
        view.needsLayout = true
    }
}
#endif

extension CALayer {
    func apply(screenLook: N64ScreenLook, scanlines: ScanlineLayer, aspectRatio: CGFloat) {
        magnificationFilter = screenLook == .sharp ? .nearest : .linear
        minificationFilter = screenLook == .sharp ? .nearest : .linear
        scanlines.isHidden = screenLook != .crt
        scanlines.aspectRatio = aspectRatio
    }
}

/// CRT look: one dark line under each of the N64's 240 lines, laid over the picture.
final class ScanlineLayer: CALayer {
    static let lineCount = 240
    var aspectRatio: CGFloat = 4.0 / 3.0

    override init() {
        super.init()
        isHidden = true
        contents = Self.pattern
        contentsGravity = .resize
        magnificationFilter = .linear
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func fit(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = aspectFitRect(aspectRatio: aspectRatio, insideRect: bounds)
        CATransaction.commit()
    }

    private static let pattern: CGImage? = {
        let height = lineCount * 2
        guard let context = CGContext(
            data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 0.38))
        for line in 0..<lineCount {
            context.fill(CGRect(x: 0, y: line * 2, width: 1, height: 1))
        }
        return context.makeImage()
    }()
}

private func aspectFitRect(aspectRatio: CGFloat, insideRect bounds: CGRect) -> CGRect {
    guard aspectRatio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    let width = min(bounds.width, bounds.height * aspectRatio)
    let height = width / aspectRatio
    return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
}
