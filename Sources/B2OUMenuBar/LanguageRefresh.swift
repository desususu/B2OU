import Foundation
import SwiftUI
import B2OUCore

private struct B2OULanguageRefreshModifier: ViewModifier {
    @State private var refreshTick = 0

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .b2ouLanguageDidChange)) { _ in
            refreshTick &+= 1
        }
    }
}

extension View {
    func b2ouRefreshesOnLanguageChange() -> some View {
        modifier(B2OULanguageRefreshModifier())
    }
}

func makeB2OULanguageObserver(_ handler: @escaping () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: .b2ouLanguageDidChange,
        object: nil,
        queue: .main
    ) { _ in
        handler()
    }
}

func removeB2OULanguageObserver(_ observer: inout NSObjectProtocol?) {
    guard let current = observer else { return }
    NotificationCenter.default.removeObserver(current)
    observer = nil
}
