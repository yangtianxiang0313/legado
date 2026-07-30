import AppNavigation
import AppUseCases
import DatabaseGRDB
import Foundation
import SwiftUI

@main
struct LegadoApp: App {
    @State private var router = AppRouter()
    @State private var library: ShelfLibrary
    @State private var sourceCatalog: SourceCatalog

    init() {
        do {
            _library = State(
                initialValue: ShelfLibrary(
                    repository: try GRDBBookShelfRepository
                        .applicationSupport()
                )
            )
            _sourceCatalog = State(
                initialValue: SourceCatalog(
                    repository: UserDefaultsSourceCatalogRepository()
                )
            )
        } catch {
            fatalError("Unable to initialize library database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let bookDetailCase = BookDetailAcceptanceCase(
                processArguments: ProcessInfo.processInfo.arguments
            ) {
                BookDetailAcceptanceView(acceptanceCase: bookDetailCase)
            } else if let startupCase = StartupAcceptanceCase(
                processArguments: ProcessInfo.processInfo.arguments
            ) {
                StartupAcceptanceView(
                    router: router,
                    library: library,
                    sourceCatalog: sourceCatalog,
                    startupCase: startupCase
                )
            } else {
                RootShellView(
                    router: router,
                    library: library,
                    sourceCatalog: sourceCatalog
                )
            }
        }
    }
}
