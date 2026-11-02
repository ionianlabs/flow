import AppKit
import SwiftUI

/// `IonianFlow --render <surface> <out.png> [--dark]` and `--render all <dir>`: draws a surface into a
/// bitmap without ordering any window in, so nothing appears on screen. Glass uses the GLS-01 recipe over
/// a Breeze still, standing in for the desktop. Add a surface by adding a line to `surfaces`.
@MainActor enum Renderer {
    struct Surface {
        var size: CGSize
        /// Draws the Breeze still behind the surface, as the desktop.
        var backdrop = false
        var make: () -> AnyView
    }

    static let surfaces: [String: Surface] = [
        "hud": hud(text: "Das Meeting ist um zehn, can you send the deck?"),
        "hud-long": hud(text: "Hallo Team, ich schicke euch die Präsentation heute Nachmittag. Für morgen haben wir drei Themen, "
            + "erstens das Budget, zweitens die Roadmap und drittens das Hiring, can you confirm the numbers by noon?"),
        "hud-empty": hud(text: ""),
        "hud-handsfree": hud(text: "", locked: true),
        "settings-general": Surface(size: CGSize(width: 820, height: 980), make: { AnyView(mainViewForRender(page: .general)) }),
        "settings-shortcuts": Surface(size: CGSize(width: 820, height: 640), make: { AnyView(mainViewForRender(page: .shortcuts)) }),
        "settings-dictation": Surface(size: CGSize(width: 820, height: 640), make: { AnyView(mainViewForRender(page: .dictation)) }),
        "settings-transcription": Surface(size: CGSize(width: 820, height: 640), make: { AnyView(mainViewForRender(page: .transcription)) }),
        "onboarding-0": onboarding(0), "onboarding-1": onboarding(1), "onboarding-2": onboarding(2),
        "onboarding-3": onboarding(3), "onboarding-4": onboarding(4),
        "vocabulary": Surface(size: CGSize(width: 820, height: 900), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularySample())) }),
        "vocabulary-large": Surface(size: CGSize(width: 820, height: 900), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularyLarge())) }),
        "vocabulary-large-category": Surface(size: CGSize(width: 820, height: 700), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularyLarge(), category: "People")) }),
        "vocabulary-search": Surface(size: CGSize(width: 820, height: 700), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularyLarge(), query: "ar")) }),
        "vocabulary-add": Surface(size: CGSize(width: 820, height: 700), make: { AnyView(mainViewForRender(page: .vocabulary, vocabulary: vocabularyLarge(), query: "Lindgren")) }),
        "vocabulary-empty": Surface(size: CGSize(width: 820, height: 640), make: { AnyView(mainViewForRender(page: .vocabulary)) }),
        "vocabulary-review": Surface(size: CGSize(width: 480, height: 600), make: {
            let store = VocabularyStore(url: vocabularySample(), watch: false)
            return AnyView(ReviewSheet(store: store, entries: store.unreviewed, onDone: {}))
        }),
        "panel-empty": Surface(size: CGSize(width: 560, height: 700), backdrop: true, make: {
            AnyView(transcriptPreview(empty: true).frame(width: 400, height: 640))
        }),
        "panel-ended": Surface(size: CGSize(width: 560, height: 700), backdrop: true, make: {
            AnyView(transcriptPreview(ended: true).frame(width: 400, height: 640))
        }),
        "panel-min": Surface(size: CGSize(width: 400, height: 460), backdrop: true, make: {
            AnyView(transcriptPreview(ended: true).frame(width: WindowLayout.transcriptMin.width, height: WindowLayout.transcriptMin.height))
        }),
        "panel-min-live": Surface(size: CGSize(width: 400, height: 460), backdrop: true, make: {
            AnyView(transcriptPreview().frame(width: WindowLayout.transcriptMin.width, height: WindowLayout.transcriptMin.height))
        }),
        "panel": Surface(size: CGSize(width: 560, height: 700), backdrop: true, make: {
            AnyView(transcriptPreview().frame(width: 400, height: 640))
        }),
    ]

    private static func hud(text: String, locked: Bool = false) -> Surface {
        Surface(size: CGSize(width: 720, height: 220), backdrop: true, make: {
            let model = OverlayModel()
            model.visible = true
            model.startedAt = Date().addingTimeInterval(-7)
            model.update(text)
            model.lang = "de-DE"
            model.level = 0.03
            model.locked = locked
            return AnyView(OverlayView(model: model))
        })
    }

    private static func onboarding(_ step: Int) -> Surface {
        Surface(size: OnboardingWindow.size, make: {
            Settings.registerDefaults()
            let model = AppModel()
            model.status = "ASR: ready"
            let notes = URL(fileURLWithPath: "/tmp/Northwind Notes", isDirectory: true)
            let known = [VaultSweeper.Vault(name: "Northwind Notes", url: notes),
                         VaultSweeper.Vault(name: "Garden", url: URL(fileURLWithPath: "/tmp/Garden", isDirectory: true))]
            return AnyView(OnboardingView(model: model, step: step, applyShortcuts: {}, connectVault: { _ in },
                                          pickVaultFolder: { nil }, onDone: {}, knownVaults: known, vault: step == 3 ? notes : nil))
        })
    }

    /// A vocabulary file with fictional terms, some of them already reviewed.
    private static func vocabularySample() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ionian-flow-render-vocabulary.md")
        let text = """
            # Ionian Flow Vocabulary

            Domain: civil engineering

            ## Terms
            - ACME
            - pull request (heard as: pool request)

            ## People
            - Marco

            ## Ignore

            <!-- ionian-flow:vault:start x -->
            ## From vault: Northwind Notes

            ### People
            - Jana Weber
            - Lena

            ### Projects
            - Harbor Bridge

            ### Acronyms
            - QA

            ### Products
            - Gemma
            <!-- ionian-flow:vault:end -->

            """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// ~45 invented terms across categories: the case that used to overwhelm the page.
    private static func vocabularyLarge() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ionian-flow-render-vocabulary-large.md")
        func block(_ name: String, _ items: [String]) -> String { "### \(name)\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        let people = ["Lena", "Marco", "Jana Weber", "Tobias Keller", "Sofia Marin", "Henrik Voss", "Amara Okafor", "Pavel Novak", "Ines Duarte", "Kai Lindner",
                      "Mira Sandoval", "Oskar Brandt", "Yuki Tanaka", "Elena Rossi"]
        let projects = ["Harbor Bridge", "Northwind Logistics", "Project Lantern", "Blue Heron", "Cedar Yard", "Mill Street Depot", "Quarry Line", "Tidewater"]
        let acronyms = ["QA", "RFI", "SLA", "ETA", "BIM", "KPI", "OKR", "SOP"]
        let products = ["Gemma", "Parakeet", "Obsidian", "Figma", "Linear", "Notion"]
        let places = ["Rotterdam", "Gdansk", "Porto", "Tallinn", "Ghent"]
        let text = "# Ionian Flow Vocabulary\n\nDomain: civil engineering\n\n## Terms\n- ACME\n- pull request (heard as: pool request)\n- retaining wall\n\n## People\n- Marco\n\n## Ignore\n\n"
            + "<!-- ionian-flow:vault:start x -->\n## From vault: Northwind Notes\n\n"
            + block("People", people) + block("Projects", projects) + block("Acronyms", acronyms) + block("Products", products) + block("Places", places)
            + "<!-- ionian-flow:vault:end -->\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func run(_ args: [String]) -> Int32 {
        IonianFont.register()
        // Highest-priority defaults, in memory only: renders never show or change this Mac's real settings.
        UserDefaults.standard.setVolatileDomain([
            "vault": "/tmp/Northwind Notes", "lastVaultScan": Date().addingTimeInterval(-3600), "dictationKey": "rightOption",
            "vocabularyReviewed": ["jana weber", "lena", "qa"],
        ], forName: UserDefaults.argumentDomain)
        let dark = args.contains("--dark")
        let names = args.filter { !$0.hasPrefix("--") }
        guard names.count == 2 else {
            print("usage: --render <surface|all> <out.png|dir> [--dark]\nsurfaces: \(surfaces.keys.sorted().joined(separator: ", "))")
            return 2
        }
        if names[0] == "all" {
            let dir = URL(fileURLWithPath: names[1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var ok = true
            for name in surfaces.keys.sorted() {
                for mode in [false, true] {
                    ok = render(name, dark: mode, to: dir.appendingPathComponent("\(name)\(mode ? "-dark" : "-light").png")) && ok
                }
            }
            return ok ? 0 : 1
        }
        return render(names[0], dark: dark, to: URL(fileURLWithPath: names[1])) ? 0 : 1
    }

    @discardableResult
    static func render(_ name: String, dark: Bool, to url: URL) -> Bool {
        guard let surface = surfaces[name] else { print("unknown surface \(name)"); return false }
        let size = surface.size
        let content = ZStack {
            if surface.backdrop { ChromeStill(name: "breeze").frame(width: size.width, height: size.height) }
            surface.make()
        }
        .environment(\.ionianOffscreen, true)
        .frame(width: size.width, height: size.height)

        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: size)
        // Never ordered in: the window only gives the hosting view somewhere to live, far off screen.
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))  // let SwiftUI finish its first pass
        host.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = size  // 2 pixels per point
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: url)
        print("wrote \(url.path)")
        return true
    }
}
