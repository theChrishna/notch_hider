import SwiftUI

struct SettingsView: View {
    @AppStorage("enabled") private var enabled = true
    @AppStorage("cornersEnabled") private var cornersEnabled = true
    @AppStorage("cornerRadius") private var cornerRadius = 20.0
    @AppStorage("bottomCorners") private var bottomCorners = false
    @AppStorage("allScreens") private var allScreens = false
    @AppStorage("mode") private var mode = "wallpaper"
    @AppStorage("barLevel") private var barLevel = 23

    var body: some View {
        Form {
            Section {
                Toggle("Enable NotchHider", isOn: $enabled)
                Toggle("Apply to all screens", isOn: $allScreens)
                Picker("Black bar method", selection: $mode) {
                    Text("Edit wallpaper").tag("wallpaper")
                    Text("Overlay window").tag("overlay")
                }
            }
            Section("Rounded corners") {
                Toggle("Show corners under the menu bar", isOn: $cornersEnabled)
                LabeledContent("Radius") {
                    HStack {
                        Slider(value: $cornerRadius, in: 4...40, step: 1)
                        Text("\(Int(cornerRadius)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!cornersEnabled)
                Toggle("Also draw corners at the bottom of the screen", isOn: $bottomCorners)
                    .disabled(!cornersEnabled)
            }
            Section("Advanced") {
                Stepper("Overlay bar window level: \(barLevel)", value: $barLevel, in: 0...30)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
