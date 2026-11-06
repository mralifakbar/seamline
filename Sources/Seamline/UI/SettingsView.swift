import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var paired: [Machine] { model.machines.filter(\.isPaired) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings").font(.largeTitle.bold())

            if model.role == .host {
                Section2(title: "Switching") {
                    SettingRow(symbol: "arrow.left.and.right", title: "Edge resistance",
                               detail: "How far you push past an edge before the pointer moves to the next Mac. The corners of each screen never switch, so Hot Corners keep working.") {
                        Picker("Edge resistance", selection: $model.resistance) {
                            ForEach(EdgeResistanceSetting.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingRow(symbol: "arrow.uturn.backward", title: "Return to this Mac") {
                        KeyCaps(text: "⌃⌥⌘ Esc")
                    }
                }
            }

            Section2(title: "Clipboard") {
                SettingRow(symbol: "doc.on.clipboard", title: "Share clipboard",
                           detail: "Text, images and PDFs you copy on one Mac are ready to paste on the next. The copy travels when the pointer crosses, and only if it changed.") {
                    Toggle("Share clipboard", isOn: $model.clipboardSync)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Section2(title: "General") {
                SettingRow(symbol: "power", title: "Open at login") {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingRow(symbol: "dock.rectangle", title: "Show in Dock") {
                    Toggle("Show in Dock", isOn: $model.showInDock)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Section2(title: "This Mac") {
                SettingRow(symbol: SystemInfo.kind.symbol, title: "Name") {
                    Text(model.identity.name)
                        .foregroundStyle(.subdued)
                        .textSelection(.enabled)
                }
                SettingRow(symbol: "person.crop.circle", title: "Role",
                           detail: model.role == .host ? "Shares its keyboard and mouse" : model.role == .guest ? "Controlled by another Mac" : "Not chosen") {
                    Button("Change…") { model.changeRole() }
                }
            }

            Section2(title: "Paired Macs") {
                if paired.isEmpty {
                    Text("No paired Macs yet.")
                        .font(.callout)
                        .foregroundStyle(.subdued)
                } else {
                    ForEach(paired) { machine in
                        SettingRow(symbol: machine.kind.symbol, title: machine.name, detail: machine.linkDetail) {
                            Button("Forget") { model.forget(machine.id) }
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
