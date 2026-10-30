import SwiftData
import SwiftUI

@main
@MainActor
struct PlushboiiApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: Pattern.self,
                PatternPiece.self,
                ControlPoint.self
            )
        } catch {
            fatalError("Unable to create the SwiftData store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.automatic)
    }
}
