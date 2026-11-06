import Foundation
import Testing
@testable import IonianFlow

extension IonianFlowTests {
@Suite struct BrainLocatorChecks {
    private func home(with brain: Bool) throws -> URL {
        let b = try FixtureBrain()
        if !brain { try FileManager.default.removeItem(at: b.root.appendingPathComponent("AGENTS.md")) }
        return b.root
    }
    private func empty() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func vaultWinsWhenItIsABrain() throws {
        let vault = try home(with: true), env = try home(with: true)
        let found = BrainLocator.find(vault: vault, environment: ["BRAIN_DIR": env.path], home: empty(), testDir: nil)
        #expect(found?.standardizedFileURL.path == vault.standardizedFileURL.path)
    }

    @Test func vaultThatIsNotABrainIsSkipped() throws {
        let vault = try home(with: false), env = try home(with: true)
        #expect(BrainLocator.find(vault: vault, environment: ["BRAIN_DIR": env.path], home: empty(), testDir: nil)?.standardizedFileURL.path == env.standardizedFileURL.path)
    }

    @Test func ionianHomeBrainThenDefaultFolder() throws {
        let h = empty()
        let ionian = h.appendingPathComponent("ih/brain")
        try FileManager.default.createDirectory(at: ionian.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try home(with: true), to: ionian)
        #expect(BrainLocator.find(vault: nil, environment: ["IONIAN_HOME": h.appendingPathComponent("ih").path], home: empty(), testDir: nil)?.standardizedFileURL.path == ionian.standardizedFileURL.path)

        let h2 = empty()
        let def = h2.appendingPathComponent("Ionian/brain")
        try FileManager.default.createDirectory(at: def.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try home(with: true), to: def)
        #expect(BrainLocator.find(vault: nil, environment: [:], home: h2, testDir: nil)?.standardizedFileURL.path == def.standardizedFileURL.path)
    }

    @Test func nilWhenNoneQualifies() throws {
        #expect(BrainLocator.find(vault: try home(with: false), environment: ["BRAIN_DIR": "/nonexistent"], home: empty(), testDir: nil) == nil)
    }

    @Test func testDirIgnoresEnvironmentAndHome() throws {
        let env = try home(with: true), h = empty()
        let def = h.appendingPathComponent("Ionian/brain")
        try FileManager.default.createDirectory(at: def.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try home(with: true), to: def)
        let t = empty()
        #expect(BrainLocator.find(vault: nil, environment: ["BRAIN_DIR": env.path], home: h, testDir: t) == nil)
        let tb = t.appendingPathComponent("Brain")
        try FileManager.default.copyItem(at: try home(with: true), to: tb)
        #expect(BrainLocator.find(vault: nil, environment: ["BRAIN_DIR": env.path], home: h, testDir: t)?.standardizedFileURL.path == tb.standardizedFileURL.path)
    }
}
}
