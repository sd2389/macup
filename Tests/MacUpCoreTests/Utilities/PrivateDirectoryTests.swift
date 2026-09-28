import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Private output directories")
struct PrivateDirectoryTests {
    @Test("Files are created owner-only in a directory created owner-only")
    func createsPrivateFiles() throws {
        let root = try TemporaryDirectory()
        let path = root.appending("shots").path
        let directory = try PrivateDirectory(path)
        try directory.write(Data("png".utf8), named: "dashboard-light.png")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: path + "/dashboard-light.png")[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    @Test("Missing parent directories are created, owner-only")
    func createsMissingParents() throws {
        // A Mac that has never used ~/.local/state has neither directory, and
        // the first thing MacUp writes there must not fail because of it.
        let root = try TemporaryDirectory()
        let path = root.appending(".local").appendingPathComponent("state").appendingPathComponent("macup").path
        let directory = try PrivateDirectory(path)
        #expect(directory.path == path)
        for created in [root.appending(".local").path, root.appending(".local").appendingPathComponent("state").path, path] {
            let mode = try FileManager.default.attributesOfItem(atPath: created)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700, "\(created) should be owner-only")
        }
    }

    @Test("A planted symlink is never written through")
    func refusesSymlinkedFile() throws {
        let root = try TemporaryDirectory()
        let victim = root.appending("victim.txt")
        try "SENTINEL".write(to: victim, atomically: true, encoding: .utf8)
        let directory = try PrivateDirectory(root.appending("shots").path)
        try FileManager.default.createSymbolicLink(atPath: directory.path + "/dashboard-light.png", withDestinationPath: victim.path)
        #expect(throws: MacUpError.self) { try directory.write(Data("png".utf8), named: "dashboard-light.png") }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "SENTINEL")
    }

    @Test("Shared, symlinked, or non-directory locations are refused")
    func refusesUnsafeDirectories() throws {
        let root = try TemporaryDirectory()
        let shared = root.appending("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        #expect(throws: MacUpError.self) { try PrivateDirectory(shared.path) }

        let link = root.appending("link")
        let real = root.appending("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: MacUpError.self) { try PrivateDirectory(link.path) }

        let file = root.appending("file")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: MacUpError.self) { try PrivateDirectory(file.path) }
    }
}
