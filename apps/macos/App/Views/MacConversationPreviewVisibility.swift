import SwiftUI

struct MacConversationPreviewVisibilityAction: Sendable {
    let update: @MainActor @Sendable (UUID, Bool) -> Void

    @MainActor
    func callAsFunction(_ source: UUID, _ isPresented: Bool) {
        update(source, isPresented)
    }
}

private struct MacConversationPreviewVisibilityKey: EnvironmentKey {
    static let defaultValue = MacConversationPreviewVisibilityAction { _, _ in }
}

extension EnvironmentValues {
    var macConversationPreviewVisibility: MacConversationPreviewVisibilityAction {
        get { self[MacConversationPreviewVisibilityKey.self] }
        set { self[MacConversationPreviewVisibilityKey.self] = newValue }
    }
}

/// A sheet's lifetime owns its token, even if its originating lazy row disappears.
struct MacConversationPreviewReadObscuration: ViewModifier {
    @Environment(\.macConversationPreviewVisibility) private var visibility
    @State private var source = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { visibility(source, true) }
            .onDisappear { visibility(source, false) }
    }
}
