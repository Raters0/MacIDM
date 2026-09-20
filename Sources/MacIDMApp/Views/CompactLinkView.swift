import AppKit
import SwiftUI

/// Bounded summary in the inspector; full redacted text is opt-in. Keep
/// copying and expansion on the same value so neither bypasses redaction.
struct CompactLinkView: View {
    let value: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TaskLinkPresentation.summary(value))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button("复制链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                Button(expanded ? "收起链接" : "展开链接") {
                    expanded.toggle()
                }
                .accessibilityValue(expanded ? Text("已展开") : Text("已折叠"))
            }
            .buttonStyle(.borderless)
            if expanded {
                ScrollView {
                    Text(value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
