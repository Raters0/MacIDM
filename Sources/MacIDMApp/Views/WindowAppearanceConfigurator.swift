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

extension AppColorScheme {
    /// SwiftUI counterpart of the setting; `nil` follows the system.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Independent AppKit windows and the menu bar panel do not inherit the
/// WindowGroup's preferred color scheme. Observe the settings object and
/// apply the theme to both the hosted SwiftUI content and the native chrome.
struct AppThemedWindow: ViewModifier {
    @ObservedObject var settings: AppSettings

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(settings.colorScheme.preferredColorScheme)
            .background(WindowAppearanceConfigurator(colorScheme: settings.colorScheme))
    }
}

extension View {
    func appThemedWindow(_ settings: AppSettings) -> some View {
        modifier(AppThemedWindow(settings: settings))
    }
}
