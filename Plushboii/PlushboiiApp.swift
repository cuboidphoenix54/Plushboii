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

        Window("Training Dashboard", id: "training-dashboard") {
            TrainingDashboardView()
        }
        .defaultSize(width: 900, height: 760)
        .commands {
            CommandGroup(after: .windowArrangement) {
                OpenTrainingDashboardCommand()
                OpenAssistantsCommand()
                OpenPersonaWindowCommand(persona: .hiro, key: "1")
                OpenPersonaWindowCommand(persona: .luna, key: "2")
                OpenPersonaWindowCommand(persona: .oden, key: "3")
            }
        }

        Window("Plush Assistants", id: "plush-assistants") {
            PersonaAssistantView()
        }
        .defaultSize(width: 460, height: 620)

        Window("Hiro", id: "persona-hiro") {
            PersonaAssistantView(fixedPersona: .hiro)
        }
        .defaultSize(width: 420, height: 580)

        Window("Luna", id: "persona-luna") {
            PersonaAssistantView(fixedPersona: .luna)
        }
        .defaultSize(width: 420, height: 580)

        Window("Oden", id: "persona-oden") {
            PersonaAssistantView(fixedPersona: .oden)
        }
        .defaultSize(width: 420, height: 580)
    }
}

private struct OpenTrainingDashboardCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Training Dashboard") { openWindow(id: "training-dashboard") }
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}

private struct OpenAssistantsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Plush Assistants") { openWindow(id: "plush-assistants") }
            .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

private struct OpenPersonaWindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    let persona: PlushPersona
    let key: KeyEquivalent

    var body: some View {
        Button("Chat with \(persona.name)") { openWindow(id: "persona-\(persona.rawValue)") }
            .keyboardShortcut(key, modifiers: [.command, .option])
    }
}
