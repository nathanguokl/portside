import XCTest

extension XCTestCase {
    /// A unique scratch directory that is removed when the test finishes.
    func temporaryDirectory(_ name: String = "Portside Tests 空間") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A minimal PE image: valid DOS and COFF identifiers but no sections or useful layout,
    /// which is all `PEExecutable.validate` inspects.
    func executable(in directory: URL, name: String = "Editor 日本語 64.exe", machine: UInt16 = 0x8664) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 0x80
        bytes[128] = 0x50; bytes[129] = 0x45
        bytes[132] = UInt8(machine & 0xff); bytes[133] = UInt8(machine >> 8)
        bytes[148] = 0xf0 // Optional header size.
        bytes[150] = 0x02 // Executable image, not DLL.
        bytes[152] = 0x0b
        bytes[153] = machine == 0x8664 ? 0x02 : 0x01
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }
}
