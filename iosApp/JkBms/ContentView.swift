import SwiftUI

// MARK: - 颜色
private let greenDark = Color(red: 0.06, green: 0.43, blue: 0.34)
private let green = Color(red: 0.11, green: 0.62, blue: 0.46)
private let amber = Color(red: 0.73, green: 0.46, blue: 0.09)
private let red = Color(red: 0.64, green: 0.18, blue: 0.18)
private let gray = Color(red: 0.53, green: 0.53, blue: 0.5)

struct ContentView: View {
    @StateObject private var vm = BmsViewModel()
    @State private var showCells = false
    @State private var showRange = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let d = vm.data {
                        HeroCard(data: d, rangeKm: vm.rangeKm(for: d), fullRangeKm: vm.fullRangeKm) { showRange = true }
                        MetricRow(data: d)
                        AvgRow(data: d) { showCells = true }
                        TempRow(data: d)
                        FooterRow(data: d)
                    } else {
                        ConnectPanel(vm: vm)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("极空BMS")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if vm.data != nil {
                        Button("断开") { vm.disconnect() }
                    } else {
                        Button("扫描") { vm.startScan() }
                    }
                }
            }
            .sheet(isPresented: $showCells) {
                if let d = vm.data { CellsSheet(data: d) }
            }
            .sheet(isPresented: $showRange) {
                RangeSheet(initial: vm.fullRangeKm) { vm.setFullRange($0) }
                    .presentationDetents([.height(260)])
            }
        }
    }
}

// MARK: - 连接面板
private struct ConnectPanel: View {
    @ObservedObject var vm: BmsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vm.data == nil && (vm.status.contains("已连接") || vm.status.contains("等待")) ? "已连接，等待数据…" : "未连接 BMS")
                .font(.headline)
            Text("点击右上角「扫描」搜索附近的 BMS 设备，点选设备连接。")
                .font(.footnote).foregroundStyle(gray)
            if !vm.devices.isEmpty {
                ForEach(vm.devices) { dev in
                    Button {
                        vm.connect(dev.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dev.name).font(.subheadline).fontWeight(.medium)
                                Text("\(dev.rssi) dBm").font(.caption2).foregroundStyle(gray)
                            }
                            Spacer()
                            Text("连接").font(.subheadline).foregroundStyle(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            Text(vm.status).font(.caption).foregroundStyle(gray)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 顶部大卡
private struct HeroCard: View {
    let data: BmsData
    let rangeKm: Double
    let fullRangeKm: Double
    let onEditRange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("剩余电量").font(.caption).foregroundStyle(gray)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.1f", data.soc)).font(.system(size: 36, weight: .medium)).foregroundStyle(greenDark)
                        Text("%").font(.headline).foregroundStyle(gray)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("剩余续航").font(.caption).foregroundStyle(gray)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.1f", rangeKm)).font(.system(size: 36, weight: .medium)).foregroundStyle(greenDark)
                        Text("km").font(.headline).foregroundStyle(gray)
                    }
                }
            }
            ProgressView(value: min(max(data.soc, 0), 100), total: 100)
                .tint(green)
                .scaleEffect(x: 1, y: 2, anchor: .center)
            HStack {
                Text(String(format: "%.1f / %.1f Ah", data.remainAh, data.nominalAh)).font(.caption).foregroundStyle(gray)
                Spacer()
                Text(String(format: "%.2f kW", data.powerW / 1000)).font(.caption).foregroundStyle(gray)
            }
            Button(action: onEditRange) {
                Text("满电预设 \(Int(fullRangeKm)) km · 点此修改").font(.caption2).foregroundStyle(.blue)
            }.buttonStyle(.plain)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 三列指标
private struct MetricRow: View {
    let data: BmsData
    var body: some View {
        HStack(spacing: 8) {
            MetricTile(label: "总压", value: String(format: "%.2f", data.totalVoltage), unit: "V")
            MetricTile(label: "电流", value: String(format: "%.1f", data.current), unit: "A")
            MetricTile(label: "MOS温度", value: String(format: "%.1f", data.mosTemp), unit: "°C")
        }
    }
}

private struct MetricTile: View {
    let label: String; let value: String; let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(gray)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 17, weight: .medium))
                Text(unit).font(.caption2).foregroundStyle(gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 平均电压 / 压差 / 状态
private struct AvgRow: View {
    let data: BmsData
    let onShowCells: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onShowCells) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("平均电芯电压").font(.caption2).foregroundStyle(gray)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(String(format: "%.3f", data.avgCell)).font(.system(size: 17, weight: .medium))
                        Text("V").font(.caption2).foregroundStyle(gray)
                    }
                    Text("点击看各电芯 ›").font(.system(size: 10)).foregroundStyle(.blue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)

            MetricTile(label: "最大压差", value: "\(data.deltaMv)", unit: "mV")
            VStack(alignment: .leading, spacing: 2) {
                Text("状态").font(.caption2).foregroundStyle(gray)
                Text(data.statusText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(data.charging ? Color.blue : (data.discharging ? greenDark : gray))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - 温度 / 保护
private struct TempRow: View {
    let data: BmsData
    var body: some View {
        HStack(spacing: 8) {
            SmallTile(label: "T1", value: String(format: "%.1f °C", data.temp1))
            SmallTile(label: "T2", value: String(format: "%.1f °C", data.temp2))
            SmallTile(label: "保护", value: "正常", color: green)
        }
    }
}

private struct SmallTile: View {
    let label: String; let value: String; var color: Color = .primary
    var body: some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(gray)
            Spacer()
            Text(value).font(.caption).fontWeight(.medium).foregroundStyle(color)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 底部
private struct FooterRow: View {
    let data: BmsData
    var body: some View {
        HStack {
            Text("循环 \(data.cycleCount)").font(.caption2).foregroundStyle(gray)
            Spacer()
            Text(String(format: "SOH %.0f%%", data.soh)).font(.caption2).foregroundStyle(gray)
            Spacer()
            Text(String(format: "满充 %.1f Ah", data.nominalAh)).font(.caption2).foregroundStyle(gray)
        }
        .padding(.top, 4)
    }
}

// MARK: - 电芯网格弹窗
private struct CellsSheet: View {
    let data: BmsData
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Text("电芯电压 · \(data.cellCount)S").font(.headline)
                        Spacer()
                        Text("压差 ").font(.caption).foregroundStyle(gray)
                        Text("\(data.deltaMv) mV").font(.caption).fontWeight(.medium).foregroundStyle(amber)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(0..<data.cellCount, id: \.self) { i in
                            CellTile(index: i, v: data.cellVoltages[i], maxV: data.maxCell, minV: data.minCell)
                        }
                    }
                    HStack(spacing: 16) {
                        Text("最高 ").font(.caption2).foregroundStyle(gray) +
                        Text("C\(data.maxCellIndex) \(String(format: "%.3fV", data.maxCell))").font(.caption2).foregroundStyle(greenDark)
                        Text("最低 ").font(.caption2).foregroundStyle(gray) +
                        Text("C\(data.minCellIndex) \(String(format: "%.3fV", data.minCell))").font(.caption2).foregroundStyle(red)
                    }
                }
                .padding(16)
            }
            .navigationTitle("电芯电压")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct CellTile: View {
    let index: Int; let v: Double; let maxV: Double; let minV: Double
    var body: some View {
        let isMax = v >= maxV - 0.0005
        let isMin = v <= minV + 0.0005
        let bg = isMax ? Color(red: 0.88, green: 0.96, blue: 0.93) : (isMin ? Color(red: 0.99, green: 0.92, blue: 0.92) : Color(.secondarySystemGroupedBackground))
        let fg = isMax ? greenDark : (isMin ? red : Color.primary)
        VStack(spacing: 1) {
            Text("C\(index + 1)").font(.system(size: 10)).foregroundStyle(fg)
            Text(String(format: "%.3f", v)).font(.system(size: 12, weight: .medium)).foregroundStyle(fg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 满电设置
private struct RangeSheet: View {
    let initial: Double
    let onSave: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(initial: Double, onSave: @escaping (Double) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _text = State(initialValue: String(Int(initial)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("满电续航里程") {
                    TextField("km", text: $text).keyboardType(.numberPad)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let v = Double(text) { onSave(v) }
                        dismiss()
                    }
                }
            }
        }
    }
}
