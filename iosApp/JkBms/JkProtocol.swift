import Foundation

/// JK-BMS JK02 协议 —— 照 JKBMS-Android 实测的 **32S 偏移**（全部小端）
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

    static func parseCellInfo(_ frame: [UInt8]) -> BmsData? {
        guard frame.count >= 200,
              frame[0] == 0x55, frame[1] == 0xAA, frame[2] == 0xEB, frame[3] == 0x90,
              frame[4] == 0x02 else { return nil }

        func u16(_ i: Int) -> Int { (Int(frame[i]) & 0xFF) | ((Int(frame[i + 1]) & 0xFF) << 8) }
        func i16(_ i: Int) -> Int { let v = u16(i); return v >= 0x8000 ? v - 0x10000 : v }
        func u32(_ i: Int) -> UInt32 {
            UInt32(frame[i]) | (UInt32(frame[i + 1]) << 8) | (UInt32(frame[i + 2]) << 16) | (UInt32(frame[i + 3]) << 24)
        }
        func i32(_ i: Int) -> Int { Int(Int32(bitPattern: u32(i))) }
        func temp(_ i: Int) -> Double { let r = i16(i); return r == 0 ? 0 : Double(r) / 10.0 }

        // 启用电芯掩码 @70（32 位），未接的串电压为 0
        let enabledMask = u32(70)
        var cells: [Double] = []
        for i in 0..<32 {
            let mv = u16(6 + i * 2)
            let enabled = enabledMask != 0 ? ((enabledMask >> UInt32(i)) & 1) == 1 : mv > 0
            if enabled && mv > 0 && mv < 0xFFFF {
                cells.append(Double(mv) / 1000.0)
            }
        }
        guard !cells.isEmpty else { return nil }

        var d = BmsData()
        d.cellVoltages = cells
        d.totalVoltage = Double(u32(150)) / 1000.0
        d.current = Double(i32(158)) / 1000.0
        d.mosTemp = temp(144)
        d.temp1 = temp(162)
        d.temp2 = temp(164)
        d.soc = Double(frame[173])
        d.remainAh = Double(u32(174)) / 1000.0
        let nominal = Double(u32(178)) / 1000.0
        d.nominalAh = nominal > 0 ? nominal : d.remainAh
        d.cycleCount = Int(u32(182))
        d.soh = Double(frame[190])
        return d
    }
}
