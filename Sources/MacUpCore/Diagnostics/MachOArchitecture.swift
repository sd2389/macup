import Darwin
import Foundation

/// What MacUp could tell about the architectures an executable was built for.
public enum ExecutableArchitectures: Sendable, Hashable {
    /// A Mach-O file built for these architectures, in the order the file
    /// lists them. Names use Apple's spelling, for example `arm64`.
    case machO([String])
    /// A script or another format that has no Mach-O header, so there is no
    /// architecture to report.
    case notMachO
    /// The file could not be read, or its header says something MacUp does not
    /// recognize. Reported as "unknown" rather than guessed at.
    case undetermined
}

/// Reads the architectures an executable was built for.
public protocol ExecutableArchitectureReading: Sendable {
    func architectures(ofExecutableAt path: String) -> ExecutableArchitectures
}

/// Reads architectures from the Mach-O header itself.
///
/// MacUp reads the bytes rather than running `lipo` or `file`, because Doctor
/// must not depend on another tool being present or on parsing its prose. Only
/// the header is read — at most a few hundred bytes, never the whole binary,
/// which for `node` would be over a hundred megabytes.
public struct MachOArchitectureReader: ExecutableArchitectureReading {
    /// A universal binary with more slices than this is not something MacUp
    /// will interpret; the count is reported as undetermined instead.
    static let maximumSlices = 32
    /// Enough for a fat header plus every slice MacUp will read.
    static let headerBytes = 8 + maximumSlices * 32

    public init() {}

    public func architectures(ofExecutableAt path: String) -> ExecutableArchitectures {
        guard let header = Self.readHeader(atPath: path) else { return .undetermined }
        return Self.parse(header)
    }

    /// Reads the leading bytes of a regular file. Opened non-blocking and
    /// checked with `fstat` so a FIFO or device cannot make Doctor hang.
    static func readHeader(atPath path: String) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: headerBytes)
        var filled = 0
        while filled < headerBytes {
            let count = read(descriptor, &buffer[filled], headerBytes - filled)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            filled += count
        }
        return Data(buffer[0..<filled])
    }

    /// Interprets a Mach-O or universal ("fat") header.
    ///
    /// A universal header is big-endian by definition; a thin header may be
    /// either, and its magic says which.
    static func parse(_ header: Data) -> ExecutableArchitectures {
        guard let magic = header.bigEndianWord(at: 0) else { return .notMachO }
        switch magic {
        case 0xFEED_FACF, 0xFEED_FACE:
            // Thin, big-endian header: the CPU type follows the magic.
            guard let cpu = header.bigEndianWord(at: 4) else { return .undetermined }
            return architecture(cpu).map { .machO([$0]) } ?? .undetermined
        case 0xCFFA_EDFE, 0xCEFA_EDFE:
            // Thin, little-endian header, which is what Apple's tools produce.
            guard let cpu = header.littleEndianWord(at: 4) else { return .undetermined }
            return architecture(cpu).map { .machO([$0]) } ?? .undetermined
        case 0xCAFE_BABE:
            return parseFat(header, sliceBytes: 20)
        case 0xCAFE_BABF:
            return parseFat(header, sliceBytes: 32)
        default:
            return .notMachO
        }
    }

    /// Reads the CPU type of every slice of a universal binary.
    ///
    /// `0xCAFEBABE` also begins a Java class file, whose next field is a
    /// version rather than a slice count. A header that does not describe a
    /// plausible number of slices is therefore left undetermined rather than
    /// read as an architecture list.
    private static func parseFat(_ header: Data, sliceBytes: Int) -> ExecutableArchitectures {
        guard let count = header.bigEndianWord(at: 4), count > 0, count <= UInt32(maximumSlices) else {
            return .undetermined
        }
        var architectures: [String] = []
        for index in 0..<Int(count) {
            guard let cpu = header.bigEndianWord(at: 8 + index * sliceBytes), let name = architecture(cpu) else {
                return .undetermined
            }
            architectures.append(name)
        }
        return .machO(architectures)
    }

    /// Apple's name for a Mach-O CPU type, or `nil` for one MacUp does not
    /// know. The high bit marks the 64-bit variant of a type.
    static func architecture(_ cpuType: UInt32) -> String? {
        switch cpuType {
        case 0x0100_000C: "arm64"
        case 0x0100_0007: "x86_64"
        case 0x0000_000C: "arm"
        case 0x0000_0007: "i386"
        case 0x0100_0012: "ppc64"
        case 0x0000_0012: "ppc"
        default: nil
        }
    }
}

extension Data {
    /// The 32-bit big-endian value at `offset`, or `nil` when the data is
    /// shorter than that.
    fileprivate func bigEndianWord(at offset: Int) -> UInt32? {
        guard let bytes = fourBytes(at: offset) else { return nil }
        return (UInt32(bytes.0) << 24) | (UInt32(bytes.1) << 16) | (UInt32(bytes.2) << 8) | UInt32(bytes.3)
    }

    fileprivate func littleEndianWord(at offset: Int) -> UInt32? {
        guard let bytes = fourBytes(at: offset) else { return nil }
        return (UInt32(bytes.3) << 24) | (UInt32(bytes.2) << 16) | (UInt32(bytes.1) << 8) | UInt32(bytes.0)
    }

    private func fourBytes(at offset: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard offset >= 0, count >= offset + 4 else { return nil }
        let start = index(startIndex, offsetBy: offset)
        return (self[start], self[start + 1], self[start + 2], self[start + 3])
    }
}
