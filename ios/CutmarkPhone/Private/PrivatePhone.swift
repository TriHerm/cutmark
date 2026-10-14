import SwiftUI

enum PrivatePhone {
    @MainActor static func screen(_ id: String) -> AnyView { AnyView(EmptyView()) }
    @MainActor static func homeBar(open: @escaping (String) -> Void) -> AnyView { AnyView(EmptyView()) }
}
