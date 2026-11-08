import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "battery.100")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("极空BMS")
                .font(.largeTitle.bold())
            Text("iOS 构建链路验证中")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
