import AppNavigation
import Foundation
import SwiftUI

@main
struct LegadoApp: App {
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            if let startupCase = StartupAcceptanceCase(
                processArguments: ProcessInfo.processInfo.arguments
            ) {
                StartupAcceptanceView(
                    router: router,
                    startupCase: startupCase
                )
            } else {
                RootShellView(router: router)
            }
        }
    }
}
