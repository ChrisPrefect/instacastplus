import SwiftUI

/// Placeholder view shown when no data is available.
struct WidgetEmptyStateView: View {
    let icon: String
    let message: String
    /// Optional secondary line (e.g. "Tap to open the app" when the widget has no exported data yet).
    var hint: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.secondary)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
    }
}
