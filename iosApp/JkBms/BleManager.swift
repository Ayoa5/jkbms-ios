import Foundation
import CoreBluetooth

/// CoreBluetooth 连接 JK-BMS：Service FFE0 / Char FFE1
/// 连接后请求一次 0x97 -> 300ms -> 0x96，BMS 持续推送 0x02；5s 无数据看门狗补发。
class BleManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let rssi: Int
    }

    static let serviceUUID = CBUUID(string: "FFE0")
    static let charUUID = CBUUID(string: "FFE1")

    var onStatus: ((String) -> Void)?
    var onData: ((BmsData) -> Void)?
    var onDevices: (([Device]) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var char: CBCharacteristic?
    private var rx: [UInt8] = []
    private var found: [String: Device] = [:]
    private var peripherals: [String: CBPeripheral] = [:]
    private var lastData = Date()
    private var watchdog: Timer?
    private var requestedOnce = false
    private var lastDeviceId: String? {
        get { UserDefaults.standard.string(forKey: "lastDeviceId") }
        set { UserDefaults.standard.set(newValue, forKey: "lastDeviceId") }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var bluetoothReady: Bool { central.state == .poweredOn }

    func startScan() {
        guard central.state == .poweredOn else { onStatus?("蓝牙未就绪/未授权"); return }
        found.removeAll(); onDevices?([])
        onStatus?("扫描中…")
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            self.onStatus?(self.found.isEmpty ? "未发现设备" : "发现 \(self.found.count) 个设备")
        }
    }

    func connect(_ id: String) {
        central.stopScan()
        guard let p = peripherals[id] else { onStatus?("设备已失效，请重新扫描"); return }
        peripheral = p
        p.delegate = self
        lastDeviceId = id
        onStatus?("连接中…")
        central.connect(p, options: nil)
    }

    func disconnect() {
        watchdog?.invalidate(); watchdog = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; char = nil; rx.removeAll(); requestedOnce = false
        onStatus?("已断开")
    }

    // MARK: - Central
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            onStatus?("蓝牙就绪")
            // 自动连上次设备（若系统缓存里有）
            if let id = lastDeviceId, let uuid = UUID(uuidString: id), peripheral == nil {
                let known = c.retrievePeripherals(withIdentifiers: [uuid])
                if let p = known.first {
                    peripheral = p
                    p.delegate = self
                    onStatus?("自动重连中…")
                    c.connect(p, options: nil)
                }
            }
        }
        else if c.state == .unauthorized { onStatus?("蓝牙未授权") }
        else { onStatus?("蓝牙不可用") }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard !name.isEmpty else { return }
        peripherals[p.identifier.uuidString] = p
        found[p.identifier.uuidString] = Device(id: p.identifier.uuidString, name: name, rssi: RSSI.intValue)
        onDevices?(Array(found.values).sorted { $0.name < $1.name })
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        onStatus?("已连接，发现服务…")
        p.discoverServices([BleManager.serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        onStatus?("连接失败：\(error?.localizedDescription ?? "未知")")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        watchdog?.invalidate(); watchdog = nil
        onStatus?("连接已断开")
    }

    // MARK: - Peripheral
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == BleManager.serviceUUID }) else {
            onStatus?("未找到 0xFFE0"); return
        }
        p.discoverCharacteristics([BleManager.charUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == BleManager.charUUID }) else {
            onStatus?("未找到 0xFFE1"); return
        }
        char = ch
        p.setNotifyValue(true, for: ch)   // 请求在 didUpdateNotificationStateFor 里发
        onStatus?("已连接，等待数据…")
    }

    /// 订阅（CCCD 写入）确认后再请求，避免订阅未生效时请求丢失
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == BleManager.charUUID else { return }
        if let e = error { onStatus?("订阅失败：\(e.localizedDescription)"); return }
        guard ch.isNotifying else { return }
        if !requestedOnce {
            requestedOnce = true
            request()
            startWatchdog()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        feed([UInt8](v))
    }

    private func request() {
        write(JkProtocol.requestDeviceInfo)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.write(JkProtocol.requestCellInfo)
        }
    }

    private func write(_ d: Data) {
        guard let p = peripheral, let ch = char else { return }
        p.writeValue(d, for: ch, type: .withoutResponse)
    }

    private func feed(_ bytes: [UInt8]) {
        rx.append(contentsOf: bytes)
        while true {
            guard let start = rx.firstIndex(of: 0x55) else {
                if rx.count > 4096 { rx.removeAll() }
                return
            }
            if start + 3 >= rx.count { if start > 0 { rx.removeFirst(start) }; return }
            if !(rx[start + 1] == 0xAA && rx[start + 2] == 0xEB && rx[start + 3] == 0x90) {
                rx.remove(at: start); continue
            }
            if start > 0 { rx.removeFirst(start) }
            if rx.count < 6 { return }
            let total = 7 + Int(rx[5])
            if rx.count < total { return }
            let frame = Array(rx[0..<total])
            rx.removeFirst(total)
            if let d = JkProtocol.parseCellInfo(frame) {
                lastData = Date()
                onData?(d)
            }
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastData) > 4 { self.request() }
        }
    }
}
