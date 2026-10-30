import SwiftUI

struct SettingsView: View {
    let updater: any AppUpdating

    private var automaticChecks: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 })
    }

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: automaticChecks)
                LabeledContent(UpdateCheckPresentation(lastCheck: updater.lastUpdateCheckDate, now: .now).label) {
                    CheckForUpdatesButton(updater: updater)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Its own view so the menu command re-renders as the updater's state changes.
struct CheckForUpdatesButton: View {
    let updater: any AppUpdating

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!UpdateCommandEnablement.isEnabled(canCheckForUpdates: updater.canCheckForUpdates))
    }
}
