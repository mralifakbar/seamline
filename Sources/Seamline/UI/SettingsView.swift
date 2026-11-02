import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var paired: [Machine] { model.machines.filter(\.isPaired) }

    var body: some View {
        Form {
            if model.role == .host {
                Section {
                    Picker("Edge resistance", selection: $model.resistance) {
                        ForEach(EdgeResistanceSetting.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Return to this Mac") {
                        Text("⌃⌥⌘ Esc")
                            .monospacedDigit()
                            .foregroundStyle(.subdued)
                    }
                } header: {
                    Text("Switching")
                } footer: {
                    Text("How far you push past an edge before the pointer moves to the next Mac. The corners of each screen never switch, so Hot Corners keep working.")
                        .foregroundStyle(.subdued)
                }
            }

            Section {
                Toggle("Share clipboard", isOn: $model.clipboardSync)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Text, images and PDFs you copy on one Mac are ready to paste on the next. The copy travels when the pointer crosses, and only if it changed.")
                    .foregroundStyle(.subdued)
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Show in Dock", isOn: $model.showInDock)
            }

            Section("This Mac") {
                LabeledContent("Name", value: model.identity.name)
                LabeledContent("Role") {
                    HStack {
                        Text(model.role == .host ? "Shares its keyboard and mouse" : model.role == .guest ? "Controlled by another Mac" : "Not chosen")
                            .foregroundStyle(.subdued)
                        Button("Change…") { model.changeRole() }
                    }
                }
            }

            Section("Paired Macs") {
                if paired.isEmpty {
                    Text("No paired Macs yet.")
                        .foregroundStyle(.subdued)
                } else {
                    ForEach(paired) { machine in
                        LabeledContent(machine.name) {
                            Button("Forget") { model.forget(machine.id) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
