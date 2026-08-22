import AppKit
import SwiftUI

/// Opening a session from the Finder arrives here rather than through SwiftUI.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        EchoEngine.current?.open(url)
    }
}

@main
struct EchoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = EchoEngine()

    var body: some Scene {
        Window("Echo", id: "echo") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 900, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { engine.newSession() }
                    .keyboardShortcut("n")
                Button("Open Session\u{2026}") { engine.openSession() }
                    .keyboardShortcut("o")
                Button("Save Session\u{2026}") { engine.saveSession() }
                    .keyboardShortcut("s")
            }
            CommandGroup(after: .newItem) {
                Button("Discard Last Phrase") { engine.discardLastLearned() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(engine.snapshot.newest == nil)
                Button("Clear Vocabulary") { engine.clearVocabulary() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Button("All Notes Off") { engine.panic() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
