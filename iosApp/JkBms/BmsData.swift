import Foundation

/// 一次 BMS 读数。单位：V / A（正=充电）/ °C / Ah。
struct BmsData {
    var soc: Double = 0
    var remainAh: Double = 0
    var nominalAh: Double = 0
    var totalVoltage: Double = 0
    var current: Double = 0
    var mosTemp: Double = 0
    var temp1: Double = 0
    var temp2: Double = 0
    var cellVoltages: [Double] = []
    var cycleCount: Int = 0
    var soh: Double = 0

    var charging: Bool { current > 0.3 }
    var discharging: Bool { current < -0.3 }
    var statusText: String {
        if charging { return "充电中" }
        if discharging { return "放电中" }
        return "待机"
    }
    var powerW: Double { totalVoltage * current }
    var cellCount: Int { cellVoltages.count }
    var avgCell: Double {
        guard !cellVoltages.isEmpty else { return 0 }
        return cellVoltages.reduce(0, +) / Double(cellVoltages.count)
    }
    var maxCell: Double { cellVoltages.max() ?? 0 }
    var minCell: Double { cellVoltages.min() ?? 0 }
    var deltaMv: Int { Int(((maxCell - minCell) * 1000).rounded()) }
    var maxCellIndex: Int { (cellVoltages.firstIndex(of: maxCell) ?? 0) + 1 }
    var minCellIndex: Int { (cellVoltages.firstIndex(of: minCell) ?? 0) + 1 }
}

/// 剩余续航 = 满电预设里程 × SOC%
func remainingRangeKm(soc: Double, fullRangeKm: Double) -> Double {
    min(max(soc, 0), 100) / 100 * fullRangeKm
}
