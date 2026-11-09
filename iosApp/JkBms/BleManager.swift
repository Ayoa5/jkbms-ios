import Foundation
import CoreBluetooth

/// 完全照 JKBMS-Android 的 BLE 方案：
/// 连接 → 订阅 → 0x97(仅一次) → 校验 device-info 里的设备密码(@62) → 认证后每 500ms 发 0x96 →
/// 固定 300 字节帧 + 帧计数器(frame[16]) + 看门狗(1s/3s) + 自动重连(1.5s)
class BleManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    struct Device: Identifiable, Hashable { let id: String; let name: String; let rssi: Int }

    static let serviceUUID = CBUUID(string: "FFE0")
    static let charUUID = CBUUID(string: "FFE1")
    static let minFrameSize = 300

    var onStatus: ((String) -> Void)?
    var onData: ((BmsData) -> Void)?
    var onDevices: (([Device]) -> Void)?
    var onAuth: ((Bool) -> Void)?

    /// BLE 连接密码（device-info 的 passcode 必须与之一致）
    var password: String = "1234"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var buffer: [UInt8] = []
    private var frameCounter: UInt8 = 0
    private var authenticated = false
    private var cellRequestInFlight = false
    private var cellRequestAt = Date()
    private var pollTimer: Timer?
    private var watchdogTimer: Timer?
    private var lastData = Date()
    private var found: [String: Device] = [:]
    private var peripherals: [String: CBPeripheral] = [:]
    private var reconnectAddress: String?
    private var lastDeviceId: String? {
        get { UserDefaults.standard.string(forKey: "lastDeviceId") }
        set { UserDefaults.standard.set(newValue, forKey: "lastDeviceId") }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 扫描 / 连接
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
        peripheral = p; p.delegate = self
        lastDeviceId = id; reconnectAddress = id
        onStatus?("连接中…")
        central.connect(p, options: nil)
    }

    func disconnect() {
        stopTimers()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; writeChar = nil; notifyChar = nil
        buffer.removeAll(); authenticated = false; reconnectAddress = nil
        onStatus?("已断开")
    }

    // MARK: - Central
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            onStatus?("蓝牙就绪")
            if let id = lastDeviceId, let uuid = UUID(uuidString: id), peripheral == nil {
                if let p = c.retrievePeripherals(withIdentifiers: [uuid]).first {
                    peripheral = p; p.delegate = self; reconnectAddress = id
                    onStatus?("自动重连中…")
                    c.connect(p, options: nil)
                }
            }
        } else if c.state == .unauthorized { onStatus?("蓝牙未授权") }
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
        scheduleReconnect()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        stopTimers()
        authenticated = false
        onStatus?("连接已断开，准备重连…")
        scheduleReconnect()
    }

    // MARK: - Peripheral
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == BleManager.serviceUUID }) else {
            onStatus?("未找到 0xFFE0"); return
        }
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let chs = s.characteristics else { onStatus?("无特征"); return }
        writeChar = chs.first { $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write) }
        notifyChar = chs.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) } ?? writeChar
        guard let n = notifyChar else { onStatus?("0xFFE1 不支持读写"); return }
        p.setNotifyValue(true, for: n)
        onStatus?("已连接，开启通知…")
    }

    /// 订阅确认（CCCD 成功）后：只发一次 0x97 请求设备信息（0x97 会蜂鸣，所以只发一次）
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == BleManager.charUUID else { return }
        if let e = error { onStatus?("订阅失败：\(e.localizedDescription)"); scheduleReconnect(); return }
        guard ch.isNotifying else { return }
        onStatus?("通知已开启，校验密码…")
        sendCommand(0x97)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        onNotify([UInt8](v))
    }

    // MARK: - 收包 / 固定 300 字节组帧
    private func onNotify(_ chunk: [UInt8]) {
        lastData = Date()
        if chunk.count >= 4, chunk[0] == 0x55, chunk[1] == 0xAA, chunk[2] == 0xEB, chunk[3] == 0x90 {
            buffer.removeAll()
        }
        buffer.append(contentsOf: chunk)
        if buffer.count >= BleManager.minFrameSize {
            let frame = Array(buffer[0..<BleManager.minFrameSize])
            buffer.removeAll()
            cellRequestInFlight = false
            guard frame.count > 4 else { return }
            switch frame[4] {
            case 0x03:   // device info：校验设备密码(@62)
                let passcode = parseCString(frame, 62, 16)
                let typed = password.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty && typed == passcode {
                    authenticated = true
                    onAuth?(true)
                    onStatus?("密码通过，读取数据…")
                    requestCellInfo()          // 只请求一次，BMS 会持续推送 0x02
                    startWatchdog()            // 5s 无数据才补发
                } else {
                    authenticated = false
                    onAuth?(false)
                    stopTimers()
                    onStatus?("密码错误（设备密码=\(passcode)）")
                }
            case 0x02:   // cell info
                guard authenticated else { return }
                if let d = JkProtocol.parseCellInfo(frame) { onData?(d) }
            default: break
            }
        } else if buffer.count > 420 {
            buffer.removeAll()
        }
    }

    private func parseCString(_ f: [UInt8], _ start: Int, _ len: Int) -> String {
        let end = min(start + len, f.count)
        guard start < end else { return "" }
        let raw = Array(f[start..<end])
        let cut = raw.firstIndex(of: 0) ?? raw.count
        return String(decoding: raw[0..<cut], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 请求
    private func sendCommand(_ cmd: UInt8) {
        guard let p = peripheral, let ch = writeChar else { return }
        var f = [UInt8](repeating: 0, count: 20)
        f[0] = 0xAA; f[1] = 0x55; f[2] = 0x90; f[3] = 0xEB
        f[4] = cmd; f[5] = 0x00
        f[16] = frameCounter
        frameCounter = frameCounter &+ 1
        var crc: UInt8 = 0
        for i in 0..<19 { crc = crc &+ f[i] }
        f[19] = crc
        p.writeValue(Data(f), for: ch, type: .withoutResponse)
    }

    /// 认证后每 500ms 请求一次 cell-info
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.requestCellInfo()
        }
    }

    private func requestCellInfo() {
        let now = Date()
        if cellRequestInFlight && now.timeIntervalSince(cellRequestAt) < 1.5 { return }
        cellRequestInFlight = true
        cellRequestAt = now
        sendCommand(0x96)
    }

    /// 看门狗：1s 检查，连续 5s 无数据才补发一次 0x96（低频，不蜂鸣）；不主动重连
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastData) > 5 {
                self.onStatus?("数据中断，补发请求…")
                self.requestCellInfo()
                self.lastData = Date()   // 延长下一次补发间隔
            }
        }
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
    }

    private func scheduleReconnect() {
        stopTimers()
        guard reconnectAddress != nil, let p = peripheral else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.peripheral != nil else { return }
            self.onStatus?("正在重连…")
            self.central.connect(p, options: nil)
        }
    }
}
