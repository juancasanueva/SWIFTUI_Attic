import SwiftUI

@main struct AtticApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 860)
        .commands { AtticCommands() }
    }
}

extension FocusedValues {
    @Entry var workspace: WorkspaceModel?
}

struct AtticCommands: Commands {
    @FocusedValue(\.workspace) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Choose Folder…") { model?.chooseFolder() }
                .keyboardShortcut("o")
                .disabled(model == nil)
            Button("Rescan") { model?.rescan() }
                .keyboardShortcut("r")
                .disabled(model?.target == nil || model?.isScanning == true)
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
