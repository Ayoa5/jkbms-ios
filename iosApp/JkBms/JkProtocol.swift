import Foundation

/// JK-BMS JK02 协议（与 Android 版一致：小端、24S offset 0 / 32S offset +32）
enum JkProtocol {
    /// 请求帧（20 字节）：AA 55 90 EB | cmd | 00 | value(4) | 填充(9) | CRC
    static func requestFrame(cmd: UInt8) -> Data {
        var f = [UInt8](repeating: 0, count: 20)
        f[0] = 0xAA; f[1] = 0x55; f[2] = 0x90; f[3] = 0xEB
        f[4] = cmd; f[5] = 0x00
        var crc: UInt8 = 0
        for i in 0..<19 { crc = crc &+ f[i] }
        f[19] = crc
        return Data(f)
    }
    static var requestCellInfo: Data { requestFrame(cmd: 0x96) }
    static var requestDeviceInfo: Data { requestFrame(cmd: 0x97) }

    /// 解析 cell-info 帧（55 AA EB 90 + type + len + data + crc）
    static func parseCellInfo(_ frame: [UInt8]) -> BmsData? {
        guard frame.count >= 7, frame[0] == 0x55, frame[1] == 0xAA, frame[2] == 0xEB, frame[3] == 0x90 else { return nil }
        let type = frame[4]
        guard type == 0x02 else { return nil }
        // 24S 帧 < 250，32S += 32
        let off = frame.count > 250 ? 32 : 0

        func u16(_ i: Int) -> Int { Int(frame[i]) | (Int(frame[i + 1]) << 8) }        // 小端
        func u32(_ i: Int) -> UInt32 {
            UInt32(frame[i]) | (UInt32(frame[i + 1]) << 8) | (UInt32(frame[i + 2]) << 16) | (UInt32(frame[i + 3]) << 24)
        }
        func i32(_ i: Int) -> Int { Int(Int32(bitPattern: u32(i))) }
        func temp(_ i: Int) -> Double {
            let raw = u16(i)
            return (raw == 0 || raw == 0xFFFF) ? 0 : Double(raw) / 10.0
        }

        var cells: [Double] = []
        for i in 0..<32 {
            let p = 6 + 2 * i
            if p + 1 >= frame.count { break }
            let mv = u16(p)
            if mv == 0 || mv >= 0xFFFF { break }
            cells.append(Double(mv) / 1000.0)
        }
        guard !cells.isEmpty else { return nil }

        var d = BmsData()
        d.cellVoltages = cells
        d.totalVoltage = Double(u32(118 + off)) / 1000.0
        d.current = Double(i32(126 + off)) / 1000.0
        d.temp1 = temp(130 + off)
        d.temp2 = temp(132 + off)
        d.mosTemp = temp(134 + off)
        if 141 + off < frame.count { d.soc = Double(frame[141 + off]) }
        d.remainAh = Double(u32(142 + off)) / 1000.0
        let nominal = Double(u32(146 + off)) / 1000.0
        d.nominalAh = nominal > 0 ? nominal : d.remainAh
        d.cycleCount = Int(u32(150 + off))
        if 158 + off < frame.count { d.soh = Double(frame[158 + off]) }
        return d
    }
}
