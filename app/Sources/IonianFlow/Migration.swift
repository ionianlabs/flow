import Foundation

/// One-time move from the app's old name: settings, the Documents folder and Application Support.
enum Migration {
    private static let oldDomain = "dev.openflow.dictation"
    private static let doneKey = "migratedFromOpenFlow"

    static func run() {
        let old = UserDefaults.standard.persistentDomain(forName: oldDomain) ?? [:]
        migrate(home: NSHomeDirectory(), defaults: .standard, oldSettings: old)
    }

    static func migrate(home: String, defaults: UserDefaults, oldSettings: [String: Any]) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        if defaults.object(forKey: "onboarded") == nil {
            for (key, value) in oldSettings { defaults.set(value, forKey: key) }
            if let frame = oldSettings["NSWindow Frame OpenFlowMain"] {
                defaults.set(frame, forKey: "NSWindow Frame IonianFlowMain")
                defaults.removeObject(forKey: "NSWindow Frame OpenFlowMain")
            }
        }

        let oldDocuments = home + "/Documents/OpenFlow"
        let moved = move(oldDocuments, to: home + "/Documents/Ionian Flow")
        _ = move(home + "/Library/Application Support/OpenFlow", to: home + "/Library/Application Support/Ionian Flow")

        // Only once the folder has moved, or the stored path would point at a folder that stays behind.
        if moved, let path = defaults.string(forKey: "transcriptsFolder"),
           path == oldDocuments || path.hasPrefix(oldDocuments + "/") {
            defaults.set(home + "/Documents/Ionian Flow" + path.dropFirst(oldDocuments.count), forKey: "transcriptsFolder")
        }
    }

    /// True when the old folder was moved over. If both exist, neither is touched.
    private static func move(_ old: String, to new: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old) else { return false }
        if fm.fileExists(atPath: new) {
            NSLog("Ionian Flow: both %@ and %@ exist, leaving them as they are", old, new)
            return false
        }
        do {
            try fm.moveItem(atPath: old, toPath: new)
            return true
        } catch {
            NSLog("Ionian Flow: moving %@ failed: %@", old, error.localizedDescription)
            return false
        }
    }
}
