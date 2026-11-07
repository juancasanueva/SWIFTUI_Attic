import SwiftUI

@main struct AtticApp: App {
    @State private var updater = SparkleUpdateChecker(automaticChecks: AutomaticUpdateChecks())

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 860)
        .commands { AtticCommands(updater: updater) }

        Window("Smart Clean", id: SmartCleanWindow.id) {
            SmartCleanWindow()
        }
        .defaultSize(width: 640, height: 720)

        Settings {
            SettingsView(updater: updater)
        }
    }
}

extension FocusedValues {
    @Entry var workspace: WorkspaceModel?
}

struct AtticCommands: Commands {
    @FocusedValue(\.workspace) private var model
    @Environment(\.openWindow) private var openWindow

    let updater: any AppUpdating

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
        CommandGroup(after: .newItem) {
            Button("Choose Folder…") { model?.chooseFolder() }
                .keyboardShortcut("o")
                .disabled(model == nil)
            Button("Rescan") { model?.rescan() }
                .keyboardShortcut("r")
                .disabled(model?.target == nil || model?.isScanning == true)
            Divider()
            Button("Smart Clean…") { openWindow(id: SmartCleanWindow.id) }
        }
        CommandGroup(before: .toolbar) {
            Button("Sunburst") { model?.chartMode = .sunburst }
                .keyboardShortcut("1")
            Button("Treemap") { model?.chartMode = .treemap }
                .keyboardShortcut("2")
            Divider()
            Button("Toggle File Browser") { model?.isBrowserVisible.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Button("Toggle Inspector") { model?.isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.canGoBack != true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.canGoForward != true)
            Button("Enclosing Folder") { model?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(model?.canGoUp != true)
        }
    }
}
