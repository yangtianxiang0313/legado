import AppNavigation
import SwiftUI

@main
struct LegadoApp: App {
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootShellView(router: router)
        }
    }
}
