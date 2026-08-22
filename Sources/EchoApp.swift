import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var engine = EchoEngine()

    var body: some Scene {
        Window("Echo", id: "echo") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 900, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Clear Vocabulary") { engine.clearVocabulary() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Button("All Notes Off") { engine.panic() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
