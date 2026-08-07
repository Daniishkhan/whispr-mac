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
        state.bootstrap()
        dispatchSelfTests()
    }

    private func dispatchSelfTests() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--selftest-connection") {
            state.runConnectionSelfTest()
        } else if let micArg = args.first(where: { $0.hasPrefix("--selftest-mic") }) {
            let seconds = Int(micArg.components(separatedBy: "=").last ?? "") ?? 3
            state.runMicSelfTest(seconds: seconds)
        } else if let fileArg = args.first(where: { $0.hasPrefix("--selftest-file=") }) {
            state.runFileSelfTest(path: String(fileArg.dropFirst("--selftest-file=".count)))
        }
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
