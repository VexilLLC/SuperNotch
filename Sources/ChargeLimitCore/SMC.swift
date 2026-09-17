import Foundation
import IOKit

/// Minimal client for the AppleSMC user client. Reads work for any user;
/// writes require root, which is why charge control lives in the helper daemon.
public final class SMCConnection {
    public enum SMCError: Error, Equatable {
        case serviceUnavailable
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case keyNotFound(String)
        case smcResult(UInt8)
        case invalidSize
    }

    private static let structSize = 80
    private static let selectorHandleEvent: UInt32 = 2
    private static let commandReadKey: UInt8 = 5
    private static let commandWriteKey: UInt8 = 6
    private static let commandKeyInfo: UInt8 = 9
    private static let resultKeyNotFound: UInt8 = 132

    // Offsets into the 80-byte SMCKeyData_t structure.
    private static let keyOffset = 0
    private static let dataSizeOffset = 28
    private static let resultOffset = 40
    private static let commandOffset = 42
    private static let bytesOffset = 48

    private var connection: io_connect_t = 0

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceUnavailable }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw SMCError.openFailed(result) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    public func hasKey(_ key: String) -> Bool {
        (try? keySize(key)) != nil
    }

    public func read(_ key: String) throws -> [UInt8] {
        let size = try keySize(key)
        var input = Self.request(key: key, command: Self.commandReadKey)
        Self.put(UInt32(size), into: &input, at: Self.dataSizeOffset)
        let output = try call(input)
        return Array(output[Self.bytesOffset..<(Self.bytesOffset + size)])
    }

    public func write(_ key: String, bytes: [UInt8]) throws {
        let size = try keySize(key)
        guard bytes.count == size else { throw SMCError.invalidSize }
        var input = Self.request(key: key, command: Self.commandWriteKey)
        Self.put(UInt32(size), into: &input, at: Self.dataSizeOffset)
        for (index, byte) in bytes.enumerated() { input[Self.bytesOffset + index] = byte }
        _ = try call(input)
    }

    private func keySize(_ key: String) throws -> Int {
        let output = try call(Self.request(key: key, command: Self.commandKeyInfo))
        let size = output[Self.dataSizeOffset..<(Self.dataSizeOffset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard size > 0, size <= 32 else { throw SMCError.invalidSize }
        return Int(size)
    }

    private func call(_ input: [UInt8]) throws -> [UInt8] {
        var input = input
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let result = IOConnectCallStructMethod(connection, Self.selectorHandleEvent, &input, Self.structSize, &output, &outputSize)
        guard result == KERN_SUCCESS else { throw SMCError.callFailed(result) }
        let smcResult = output[Self.resultOffset]
        if smcResult == Self.resultKeyNotFound {
            throw SMCError.keyNotFound(String(decoding: input[0..<4].reversed(), as: UTF8.self))
        }
        guard smcResult == 0 else { throw SMCError.smcResult(smcResult) }
        return output
    }

    private static func request(key: String, command: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: structSize)
        put(fourCharCode(key), into: &bytes, at: keyOffset)
        bytes[commandOffset] = command
        return bytes
    }

    private static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { raw in
            for index in 0..<4 { bytes[offset + index] = raw[index] }
        }
    }

    public static func fourCharCode(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Which SMC keys this Mac uses to control charging.
public enum ChargingControlScheme: String, Codable, Sendable {
    /// Apple silicon firmware from macOS 15 onward: `CHTE`, 4 bytes.
    case chte = "CHTE"
    /// Earlier Apple silicon and T2 firmware: `CH0B` and `CH0C`, 1 byte each.
    case ch0b = "CH0B"

    public var inhibitBytes: [UInt8] {
        switch self {
        case .chte: return [1, 0, 0, 0]
        case .ch0b: return [2]
        }
    }

    public var enableBytes: [UInt8] {
        switch self {
        case .chte: return [0, 0, 0, 0]
        case .ch0b: return [0]
        }
    }
}

/// Keys that switch the power adapter off so the Mac runs from its battery,
/// in the order they are tried. Values match the open-source `batt` tool.
public enum AdapterControlKey: String, Codable, CaseIterable, Sendable {
    case ch0i = "CH0I"
    case ch0j = "CH0J"
    /// Newer firmware.
    case chie = "CHIE"

    public var disableByte: UInt8 { self == .chie ? 0x08 : 0x01 }
}

/// MagSafe LED values for the `ACLC` key.
public enum MagSafeLED: UInt8, Sendable {
    case system = 0
    case off = 1
    case green = 3
    case orange = 4
}

/// High-level charge control on top of the SMC.
public final class ChargingController {
    public let scheme: ChargingControlScheme
    public let supportsLED: Bool
    /// Every adapter key this Mac has, in priority order.
    public let supportedAdapterKeys: [AdapterControlKey]
    /// Keys still worth trying to switch the adapter off; the first is in use.
    public private(set) var adapterKeys: [AdapterControlKey]
    public var supportsAdapterControl: Bool { !adapterKeys.isEmpty }
    private let smc: SMCConnection

    public init(smc: SMCConnection) throws {
        self.smc = smc
        if smc.hasKey("CHTE") {
            scheme = .chte
        } else if smc.hasKey("CH0B"), smc.hasKey("CH0C") {
            scheme = .ch0b
        } else {
            throw SMCConnection.SMCError.keyNotFound("CHTE")
        }
        supportsLED = smc.hasKey("ACLC")
        supportedAdapterKeys = AdapterControlKey.allCases.filter { smc.hasKey($0.rawValue) }
        adapterKeys = supportedAdapterKeys
    }

    public func isChargingInhibited() throws -> Bool {
        switch scheme {
        case .chte: return try smc.read("CHTE").contains { $0 != 0 }
        case .ch0b: return try smc.read("CH0B").contains { $0 != 0 }
        }
    }

    public func setChargingInhibited(_ inhibited: Bool) throws {
        let bytes = inhibited ? scheme.inhibitBytes : scheme.enableBytes
        switch scheme {
        case .chte:
            try smc.write("CHTE", bytes: bytes)
        case .ch0b:
            try smc.write("CH0B", bytes: bytes)
            try smc.write("CH0C", bytes: bytes)
        }
    }

    /// True when any adapter key currently has the adapter switched off.
    public func isAdapterDisabled() throws -> Bool {
        try supportedAdapterKeys.contains { try smc.read($0.rawValue).first.map { $0 != 0 } ?? false }
    }

    /// Disabling writes the active key; enabling clears every supported key so
    /// nothing can be left switched off.
    public func setAdapterDisabled(_ disabled: Bool) throws {
        if disabled {
            guard let key = adapterKeys.first else { return }
            try smc.write(key.rawValue, bytes: [key.disableByte])
        } else {
            for key in supportedAdapterKeys { try smc.write(key.rawValue, bytes: [0]) }
        }
    }

    /// Drops the active adapter key after it failed to take effect. Returns
    /// false when there is nothing left to try.
    public func fallBackToNextAdapterKey() -> Bool {
        guard !adapterKeys.isEmpty else { return false }
        adapterKeys.removeFirst()
        return !adapterKeys.isEmpty
    }

    /// Whether a charger is physically connected, even if it has been switched off.
    public func isPluggedIn() -> Bool? {
        guard let value = try? smc.read("AC-W").first else { return nil }
        return Int8(bitPattern: value) > 0
    }

    public func led() throws -> MagSafeLED? {
        guard supportsLED, let value = try smc.read("ACLC").first else { return nil }
        return MagSafeLED(rawValue: value)
    }

    public func setLED(_ state: MagSafeLED) throws {
        guard supportsLED else { return }
        try smc.write("ACLC", bytes: [state.rawValue])
    }
}
