import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Mach-O architecture reading")
struct MachOArchitectureTests {
    /// Assembles the bytes a Mach-O or universal header begins with, so the
    /// tests describe real file layouts without committing binaries.
    private enum Header {
        static func thin(magic: UInt32, cpuType: UInt32, bigEndian: Bool) -> Data {
            var data = Data()
            data.append(word(magic, bigEndian: true))
            data.append(word(cpuType, bigEndian: bigEndian))
            data.append(Data(repeating: 0, count: 24))
            return data
        }

        /// A universal header. Slice fields after the CPU type are zero-filled;
        /// MacUp reads only the CPU type of each slice.
        static func fat(_ cpuTypes: [UInt32], sliceBytes: Int = 20, declaredCount: UInt32? = nil) -> Data {
            var data = Data()
            data.append(word(0xCAFE_BABE, bigEndian: true))
            data.append(word(declaredCount ?? UInt32(cpuTypes.count), bigEndian: true))
            for cpuType in cpuTypes {
                data.append(word(cpuType, bigEndian: true))
                data.append(Data(repeating: 0, count: sliceBytes - 4))
            }
            return data
        }

        static func word(_ value: UInt32, bigEndian: Bool) -> Data {
            let bytes: [UInt8] = [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ]
            return Data(bigEndian ? bytes : bytes.reversed())
        }
    }

    @Test("A thin arm64 header, as Apple's tools write it, reads as arm64")
    func littleEndianArm64() {
        // 0xFEEDFACF stored little-endian, which on disk begins cf fa ed fe.
        let header = Header.thin(magic: 0xCFFA_EDFE, cpuType: 0x0100_000C, bigEndian: false)
        #expect(MachOArchitectureReader.parse(header) == .machO(["arm64"]))
    }

    @Test("A thin x86_64 header reads as x86_64")
    func littleEndianIntel() {
        let header = Header.thin(magic: 0xCFFA_EDFE, cpuType: 0x0100_0007, bigEndian: false)
        #expect(MachOArchitectureReader.parse(header) == .machO(["x86_64"]))
    }

    @Test("A big-endian thin header is read with its own byte order")
    func bigEndianThinHeader() {
        let header = Header.thin(magic: 0xFEED_FACF, cpuType: 0x0100_000C, bigEndian: true)
        #expect(MachOArchitectureReader.parse(header) == .machO(["arm64"]))
    }

    @Test("A universal binary reports every slice in file order")
    func universalBinary() {
        let header = Header.fat([0x0100_0007, 0x0100_000C])
        #expect(MachOArchitectureReader.parse(header) == .machO(["x86_64", "arm64"]))
    }

    @Test("A 64-bit universal header uses the wider slice entries")
    func universal64Binary() {
        var header = MachOArchitectureTests.Header.word(0xCAFE_BABF, bigEndian: true)
        header.append(MachOArchitectureTests.Header.word(1, bigEndian: true))
        header.append(MachOArchitectureTests.Header.word(0x0100_000C, bigEndian: true))
        header.append(Data(repeating: 0, count: 28))
        #expect(MachOArchitectureReader.parse(header) == .machO(["arm64"]))
    }

    @Test("A shell script has no Mach-O header and reports nothing to compare")
    func scriptIsNotMachO() {
        #expect(MachOArchitectureReader.parse(Data("#!/bin/bash -pu\nset -u\n".utf8)) == .notMachO)
        #expect(MachOArchitectureReader.parse(Data("#!/usr/bin/env node\n".utf8)) == .notMachO)
    }

    @Test("A file too short to hold a header reports nothing to compare")
    func shortFileIsNotMachO() {
        #expect(MachOArchitectureReader.parse(Data([0xCF, 0xFA])) == .notMachO)
    }

    @Test("A Java class file, which shares the universal magic, is left undetermined")
    func javaClassFileIsUndetermined() {
        // ca fe ba be followed by minor and major version, not a slice count.
        var header = Header.word(0xCAFE_BABE, bigEndian: true)
        header.append(Header.word(0x0000_0041, bigEndian: true))
        header.append(Data(repeating: 0, count: 24))
        #expect(MachOArchitectureReader.parse(header) == .undetermined)
    }

    @Test("A universal header claiming more slices than MacUp reads is left undetermined")
    func tooManySlicesIsUndetermined() {
        let header = Header.fat([0x0100_000C], declaredCount: 4_096)
        #expect(MachOArchitectureReader.parse(header) == .undetermined)
    }

    @Test("A CPU type MacUp does not know is left undetermined rather than named")
    func unknownCPUTypeIsUndetermined() {
        let header = Header.thin(magic: 0xCFFA_EDFE, cpuType: 0x0100_00FF, bigEndian: false)
        #expect(MachOArchitectureReader.parse(header) == .undetermined)
    }

    @Test("Only the header is read, not the rest of a large file")
    func readsOnlyTheHeader() throws {
        let directory = try TemporaryDirectory(prefix: "macup-macho")
        let path = directory.appending("pretend-binary").path
        var contents = Header.thin(magic: 0xCFFA_EDFE, cpuType: 0x0100_000C, bigEndian: false)
        contents.append(Data(repeating: 0xAB, count: 512 * 1024))
        try contents.write(to: URL(fileURLWithPath: path))

        let header = try #require(MachOArchitectureReader.readHeader(atPath: path))
        #expect(header.count == MachOArchitectureReader.headerBytes)
        #expect(MachOArchitectureReader().architectures(ofExecutableAt: path) == .machO(["arm64"]))
    }

    @Test("A path that does not exist is undetermined, not a crash")
    func missingFileIsUndetermined() {
        let reader = MachOArchitectureReader()
        #expect(reader.architectures(ofExecutableAt: "/nonexistent/macup-doctor-test") == .undetermined)
    }

    @Test("A directory is undetermined, because only regular files are read")
    func directoryIsUndetermined() throws {
        let directory = try TemporaryDirectory(prefix: "macup-macho")
        #expect(MachOArchitectureReader().architectures(ofExecutableAt: directory.path) == .undetermined)
    }
}
