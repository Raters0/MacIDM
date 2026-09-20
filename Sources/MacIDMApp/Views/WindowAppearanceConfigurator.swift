import AppKit
import SwiftUI

/// Apply the shared theme to native chrome in independent hosted windows.
struct WindowAppearanceConfigurator: NSViewRepresentable {
    let colorScheme: AppColorScheme

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            view.window?.appearance = appearance
        }
    }

    private var appearance: NSAppearance? {
        switch colorScheme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
