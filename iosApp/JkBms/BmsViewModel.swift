import Foundation
import Combine

@MainActor
final class BmsViewModel: ObservableObject {
    @Published var data: BmsData?
    @Published var status: String = "未连接"
    @Published var devices: [BleManager.Device] = []
    @Published var fullRangeKm: Double

    let ble = BleManager()

    init() {
        let saved = UserDefaults.standard.double(forKey: "fullRangeKm")
        fullRangeKm = saved > 0 ? saved : 100
        ble.onStatus = { [weak self] s in self?.status = s }
        ble.onDevices = { [weak self] d in self?.devices = d }
        ble.onData = { [weak self] d in self?.data = d }
    }

    func startScan() { ble.startScan() }
    func connect(_ id: String) { ble.connect(id) }
    func disconnect() { ble.disconnect() }

    func setFullRange(_ km: Double) {
        let v = min(max(km, 1), 2000)
        fullRangeKm = v
        UserDefaults.standard.set(v, forKey: "fullRangeKm")
    }

    func rangeKm(for d: BmsData) -> Double { remainingRangeKm(soc: d.soc, fullRangeKm: fullRangeKm) }
}
