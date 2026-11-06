import Foundation

/// Finds the Ionian Brain the way the Brain plugin does: the first of the folder chosen on the Instinct page (F3.3), the connected vault, `$BRAIN_DIR`,
/// `$IONIAN_HOME/brain` and `~/Ionian/brain` that passes `BrainLines.isBrain`. Nil when none does.
/// With a test directory only the vault and `<testDir>/Brain` count, so a test never sees the real brain.
enum BrainLocator {
    static func candidates(chosen: URL? = nil, vault: URL?, environment: [String: String], home: URL, testDir: URL?) -> [URL] {
        func dir(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }
        var list: [URL] = []
        if let chosen { list.append(chosen) }
        if let vault { list.append(vault) }
        if let testDir { return list + [testDir.appendingPathComponent("Brain", isDirectory: true)] }
        if let d = environment["BRAIN_DIR"], !d.isEmpty { list.append(dir(d)) }
        if let h = environment["IONIAN_HOME"], !h.isEmpty { list.append(dir(h).appendingPathComponent("brain", isDirectory: true)) }
        list.append(home.appendingPathComponent("Ionian/brain", isDirectory: true))
        return list
    }

    static func find(chosen: URL? = nil, vault: URL?, environment: [String: String], home: URL, testDir: URL?) -> URL? {
        candidates(chosen: chosen, vault: vault, environment: environment, home: home, testDir: testDir).first(where: BrainLines.isBrain)
    }

    /// The brain of the running app.
    static func current() -> URL? {
        find(chosen: Settings.instinctBrainFolder, vault: Settings.vault, environment: ProcessInfo.processInfo.environment,
             home: FileManager.default.homeDirectoryForCurrentUser, testDir: Settings.testDir)
    }
}
