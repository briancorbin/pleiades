import Foundation
import Maia

/// Wraps an `ElectraCar` in the ELM327 dialect. The same `ELM327Session` that
/// talks to a real dongle talks to this unmodified — that's the point.
public actor ELM327Emulator: OBDTransport {
    private let car: ElectraCar
    private let supported: Set<UInt8>

    /// `supported` defaults to Maia's full catalog plus PID 01 (MIL status);
    /// narrow it to rehearse the real car declining a PID.
    public init(car: ElectraCar, supported: Set<UInt8>? = nil) {
        self.car = car
        self.supported = supported ?? Set(PID.all.map(\.code)).union([0x01])
    }

    public func send(_ command: String) async throws -> String {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if cmd.hasPrefix("AT") {
            return cmd == "ATZ" ? "ELM327 v1.5 (Electra)\r\r" : "OK\r\r"
        }

        // Mode 03/04: stored trouble codes.
        if cmd == "03" {
            let faults = await car.currentFaults()
            let bytes: [UInt8] = [0x43, UInt8(faults.count)] + faults.flatMap { [$0.bytes.0, $0.bytes.1] }
            return bytes.map { String(format: "%02X", $0) }.joined() + "\r\r"
        }
        if cmd == "04" {
            await car.clearFaults()
            return "44\r\r"
        }

        guard cmd.count == 4, cmd.hasPrefix("01"), let code = UInt8(cmd.suffix(2), radix: 16) else {
            return "?\r\r"
        }

        if code % 0x20 == 0 {
            if let mask = Self.supportMask(page: code, codes: supported) {
                return reply(code: code, payload: mask)
            }
            return "NO DATA\r\r"
        }

        guard supported.contains(code), let payload = await encode(code) else {
            return "NO DATA\r\r"
        }
        return reply(code: code, payload: payload)
    }

    private func reply(code: UInt8, payload: [UInt8]) -> String {
        ([0x41, code] + payload).map { String(format: "%02X", $0) }.joined() + "\r\r"
    }

    /// The 4-byte support bitmask for one page (PID 00, 20, 40, …), or nil if
    /// nothing on or beyond this page is supported.
    static func supportMask(page: UInt8, codes: Set<UInt8>) -> [UInt8]? {
        guard codes.contains(where: { $0 > page }) else { return nil }
        var mask: [UInt8] = [0, 0, 0, 0]
        for code in codes where code > page && code <= page &+ 0x20 {
            let index = Int(code - page - 1)
            mask[index / 8] |= 0x80 >> (index % 8)
        }
        // Next-page marker (PID page+20) so the walk continues.
        if codes.contains(where: { $0 > page &+ 0x20 }) {
            mask[3] |= 0x01
        }
        return mask
    }

    private func encode(_ code: UInt8) async -> [UInt8]? {
        let s = await car.snapshot()
        switch code {
        case 0x01:
            let faults = await car.currentFaults()
            let a = UInt8(min(faults.count, 0x7F)) | (faults.isEmpty ? 0 : 0x80)
            return [a, 0, 0, 0]
        case 0x04: return [u8(s.loadPct * 2.55)]
        case 0x05: return [u8(s.coolantC + 40)]
        case 0x06, 0x07: return [u8(100 * 1.28)]  // trim 0%
        case 0x0B: return [u8(s.mapKPa)]
        case 0x0C: return u16(s.rpm * 4)
        case 0x0D: return [u8(s.speedKmh)]
        case 0x0E: return [u8((s.timingBTDC + 64) * 2)]
        case 0x0F: return [u8(s.intakeC + 40)]
        case 0x10: return u16(s.mafGs * 100)
        case 0x11: return [u8(s.throttlePct * 2.55)]
        case 0x1F: return u16(s.runTimeS)
        case 0x21: return u16(s.distanceWithMILKm)
        case 0x23: return u16(s.rpm > 0 ? 420 : 0)  // ~4.2 MPa rail, /10 encoding
        case 0x2F: return [u8(s.fuelPct * 2.55)]
        case 0x31: return u16(s.distanceSinceClearKm)
        case 0x33: return [u8(s.baroKPa)]
        case 0x3C: return u16((s.catTempC + 40) * 10)
        case 0x42: return u16(s.voltage * 1000)
        case 0x45: return [u8(s.throttlePct * 2.55)]
        case 0x46: return [u8(s.ambientC + 40)]
        case 0x5C: return [u8(s.oilTempC + 40)]
        case 0x5E: return u16(s.fuelRateLh * 20)
        default: return nil
        }
    }

    private func u8(_ value: Double) -> UInt8 {
        UInt8(min(max(value.rounded(), 0), 255))
    }

    private func u16(_ value: Double) -> [UInt8] {
        let word = UInt16(min(max(value.rounded(), 0), 65535))
        return [UInt8(word >> 8), UInt8(word & 0xFF)]
    }
}
