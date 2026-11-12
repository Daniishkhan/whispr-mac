import SwiftUI

@main
struct WhisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: appDelegate.state)
        } label: {
            MenuBarIcon(state: appDelegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if dispatchSelfTests() { return }
        state.bootstrap()
    }

    /// Returns true when a CLI selftest has taken ownership of this process.
    /// Keep this before bootstrap so selftests never register hotkeys or open UI.
    @discardableResult
    private func dispatchSelfTests() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--selftest-connection") {
            state.runConnectionSelfTest()
            return true
        }
        if args.contains("--selftest-polish-mock") {
            state.runPolishMockSelfTest()
            return true
        }
        if let polishArg = args.first(where: { $0.hasPrefix("--selftest-polish") }) {
            let prefix = "--selftest-polish="
            guard polishArg.hasPrefix(prefix) else {
                dbg("selftest-polish: expected --selftest-polish=<text>")
                exit(2)
            }
            // Drop only the exact prefix so embedded '=' is preserved.
            state.runPolishSelfTest(text: String(polishArg.dropFirst(prefix.count)))
            return true
        }
        if let vocabArg = args.first(where: { $0.hasPrefix("--selftest-vocab") }) {
            let prefix = "--selftest-vocab="
            state.runVocabularySelfTest(path: vocabArg.hasPrefix(prefix) ? String(vocabArg.dropFirst(prefix.count)) : nil)
            return true
        }
        if let micArg = args.first(where: { $0.hasPrefix("--selftest-mic") }) {
            let seconds = Int(micArg.components(separatedBy: "=").last ?? "") ?? 3
            state.runMicSelfTest(seconds: seconds)
            return true
        }
        if let fileArg = args.first(where: { $0.hasPrefix("--selftest-file=") }) {
            state.runFileSelfTest(path: String(fileArg.dropFirst("--selftest-file=".count)))
            return true
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }
}

struct MenuBarIcon: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(systemName: state.menuBarIconName)
    }
}
