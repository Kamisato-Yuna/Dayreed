import DayreedCore
import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    ForEach(Appearance.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
            }
            Section("关于") {
                LabeledContent("版本", value: "\(ProductInfo.version) (\(ProductInfo.build))")
                LabeledContent("许可", value: "MIT")
                Link("GitHub 项目", destination: URL(string: ProductInfo.repository)!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 290)
        .navigationTitle("设置")
    }
}
