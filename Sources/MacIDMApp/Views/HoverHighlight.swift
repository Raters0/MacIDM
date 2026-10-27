import SwiftUI

/// Hover affordance for the flat sidebar rows: plain-style buttons gave
/// zero feedback under the pointer otherwise.
struct HoverHighlight: ViewModifier {
    var isActive = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .fill(
                        isHovering && !isActive
                            ? Color.primary.opacity(0.05) : Color.clear
                    )
            )
            .onHover { hovering in
                isHovering = hovering
            }
            .pointerCursorOnHover()
    }
}
