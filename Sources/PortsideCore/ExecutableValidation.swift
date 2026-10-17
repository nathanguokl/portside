import Foundation

public enum PEMachine: String, Sendable { case x86, x64 }

public enum PEExecutable {
    /// Checks the DOS and COFF headers without loading the whole installer into memory.
    @discardableResult public static func validate(url: URL) throws -> PEMachine {
        guard url.isFileURL, url.pathExtension.lowercased() == "exe" else {
            throw PortsideError.invalidExecutable("Select a Windows .exe file.")
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let fileSize = values?.fileSize, fileSize >= 88 else {
            throw PortsideError.invalidExecutable("The file is missing, unreadable, or too small to be a Windows program: \(url.path)")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw PortsideError.invalidExecutable("Cannot read \(url.lastPathComponent): \(error.localizedDescription)") }
        defer { try? handle.close() }
        func read(_ count: Int) throws -> [UInt8] { Array(try handle.read(upToCount: count) ?? Data()) }
        let dos = try read(64)
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else {
            throw PortsideError.invalidExecutable("The file has no Windows MZ header.")
        }
        let offset = UInt32(dos[60]) | UInt32(dos[61]) << 8 | UInt32(dos[62]) << 16 | UInt32(dos[63]) << 24
        guard offset >= 64, UInt64(offset) + 26 <= UInt64(fileSize) else {
            throw PortsideError.invalidExecutable("The Windows PE header is truncated or corrupt.")
        }
        try handle.seek(toOffset: UInt64(offset))
        let header = try read(26)
        guard header.count == 26, Array(header[0..<4]) == [0x50, 0x45, 0, 0] else {
            throw PortsideError.invalidExecutable("The file has no valid PE signature.")
        }
        let machine = UInt16(header[4]) | UInt16(header[5]) << 8
        let characteristics = UInt16(header[22]) | UInt16(header[23]) << 8
        let optionalSize = UInt16(header[20]) | UInt16(header[21]) << 8
        guard characteristics & 0x0002 != 0, characteristics & 0x2000 == 0, optionalSize >= 2,
              UInt64(offset) + 24 + UInt64(optionalSize) <= UInt64(fileSize) else {
            throw PortsideError.invalidExecutable("Select a complete executable program, not a DLL or damaged file.")
        }
        let magic = UInt16(header[24]) | UInt16(header[25]) << 8
        switch (machine, magic) {
        case (0x8664, 0x20b): return .x64
        case (0x014c, 0x10b): return .x86
        default: throw PortsideError.invalidExecutable("Only Intel x64 and x86 Windows executables are supported by this MVP. ARM Windows applications require a different runtime.")
        }
    }
}
