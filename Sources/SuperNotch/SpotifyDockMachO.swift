import Foundation

enum SpotifyDockMachOError: LocalizedError, Equatable {
    case malformed(String)
    case unsupported
    case insufficientHeaderSpace

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): return "Malformed Spotify executable: \(detail)"
        case .unsupported: return "This Spotify executable format is not supported."
        case .insufficientHeaderSpace: return "Spotify's executable has no safe room for the Dock helper."
        }
    }
}

enum SpotifyDockMachO {
    static let helperInstallName = "@rpath/SuperNotchSpotifyDock.dylib"
    private static let magic64: UInt32 = 0xFEED_FACF
    private static let loadDylib: UInt32 = 0xC
    private static let segment64: UInt32 = 0x19
    private static let symtab: UInt32 = 0x2

    static func containsHelper(in data: Data) throws -> Bool {
        let header = try parseHeader(data)
        var cursor = header.commandsOffset
        for _ in 0..<header.commandCount {
            let size = try commandSize(data, at: cursor, commandsEnd: header.commandsEnd)
            if readUInt32(data, at: cursor) == loadDylib {
                let nameOffset = Int(readUInt32(data, at: cursor + 8))
                guard nameOffset >= 24, nameOffset < size else { throw SpotifyDockMachOError.malformed("invalid dylib name") }
                if readCString(data, at: cursor + nameOffset, limit: size - nameOffset) == helperInstallName { return true }
            }
            cursor += size
        }
        return false
    }

    static func containsHelper(at url: URL) throws -> Bool {
        try containsHelper(in: Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func insertHelper(into url: URL) throws {
        var data = try Data(contentsOf: url)
        guard try !containsHelper(in: data) else { return }
        let header = try parseHeader(data)
        let command = makeDylibCommand(helperInstallName)
        let firstContentOffset = try earliestContentOffset(data, header: header)
        let available = firstContentOffset - header.commandsEnd
        guard available >= command.count + 16 else { throw SpotifyDockMachOError.insufficientHeaderSpace }

        data.replaceSubrange(header.commandsEnd..<(header.commandsEnd + command.count), with: command)
        writeUInt32(&data, at: 16, value: UInt32(header.commandCount + 1))
        writeUInt32(&data, at: 20, value: UInt32(header.commandsSize + command.count))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private struct Header {
        let commandsOffset: Int
        let commandCount: Int
        let commandsSize: Int
        var commandsEnd: Int { commandsOffset + commandsSize }
    }

    private static func parseHeader(_ data: Data) throws -> Header {
        guard data.count >= 32, readUInt32(data, at: 0) == magic64 else { throw SpotifyDockMachOError.unsupported }
        let count = Int(readUInt32(data, at: 16))
        let size = Int(readUInt32(data, at: 20))
        guard count > 0, size > 0, 32 + size <= data.count else { throw SpotifyDockMachOError.malformed("invalid load-command table") }
        return Header(commandsOffset: 32, commandCount: count, commandsSize: size)
    }

    private static func commandSize(_ data: Data, at offset: Int, commandsEnd: Int) throws -> Int {
        guard offset >= 0, offset + 8 <= commandsEnd, offset + 8 <= data.count else { throw SpotifyDockMachOError.malformed("truncated load command") }
        let size = Int(readUInt32(data, at: offset + 4))
        guard size >= 8, offset + size <= commandsEnd else { throw SpotifyDockMachOError.malformed("invalid load-command size") }
        return size
    }

    private static func earliestContentOffset(_ data: Data, header: Header) throws -> Int {
        var earliest = Int.max
        var cursor = header.commandsOffset
        for _ in 0..<header.commandCount {
            let size = try commandSize(data, at: cursor, commandsEnd: header.commandsEnd)
            switch readUInt32(data, at: cursor) {
            case segment64:
                guard size >= 72 else { throw SpotifyDockMachOError.malformed("short segment command") }
                let fileOffset = Int(readUInt64(data, at: cursor + 40))
                if fileOffset > 0 { earliest = min(earliest, fileOffset) }
                let sectionCount = Int(readUInt32(data, at: cursor + 64))
                guard 72 + sectionCount * 80 <= size else { throw SpotifyDockMachOError.malformed("invalid section table") }
                for section in 0..<sectionCount {
                    let offset = Int(readUInt32(data, at: cursor + 72 + section * 80 + 48))
                    if offset > 0 { earliest = min(earliest, offset) }
                }
            case symtab:
                guard size >= 24 else { throw SpotifyDockMachOError.malformed("short symbol table command") }
                for field in [8, 16] {
                    let offset = Int(readUInt32(data, at: cursor + field))
                    if offset > 0 { earliest = min(earliest, offset) }
                }
            default: break
            }
            cursor += size
        }
        guard earliest != Int.max, earliest >= header.commandsEnd else { throw SpotifyDockMachOError.malformed("could not locate first file content") }
        return earliest
    }

    private static func makeDylibCommand(_ value: String) -> Data {
        let string = Array(value.utf8) + [0]
        let size = ((24 + string.count + 7) / 8) * 8
        var data = Data(count: size)
        writeUInt32(&data, at: 0, value: loadDylib)
        writeUInt32(&data, at: 4, value: UInt32(size))
        writeUInt32(&data, at: 8, value: 24)
        data.replaceSubrange(24..<(24 + string.count), with: string)
        return data
    }

    private static func readCString(_ data: Data, at offset: Int, limit: Int) -> String {
        let bytes = data[offset..<min(data.count, offset + limit)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<(offset + 4)].enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        return data[offset..<(offset + 8)].enumerated().reduce(0) { $0 | (UInt64($1.element) << UInt64($1.offset * 8)) }
    }

    private static func writeUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8)) }
    }
}
