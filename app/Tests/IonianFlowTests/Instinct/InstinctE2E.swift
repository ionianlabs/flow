import Foundation
@testable import IonianFlow

/// Runs the real `InstinctSweep` on a fixture brain and scores what it writes against labelled planted items.
enum InstinctE2E {
    typealias Label = InstinctGemmaFixtures.Label

    struct Written { var category: String, project: String, due: String?, quote: String, line: String }

    struct Score {
        var title: String
        var written: [Written] = []
        var matches: [Int?] = []          // per written line: index of the planted label, nil for junk
        var details: [[String]] = []      // per written line: what differs from the label
        var labels: [Label] = []
        var seconds = 0.0
        var footer = ""

        var real: Int { matches.compactMap { $0 }.count }
        var found: Int { Set(matches.compactMap { $0 }).count }
        var reachable: Int { labels.filter(\.reachable).count }
        var foundReachable: Int { Set(matches.compactMap { $0 }).filter { labels[$0].reachable }.count }
        var precision: Double { written.isEmpty ? 1 : Double(real) / Double(written.count) }
        var recall: Double { labels.isEmpty ? 1 : Double(found) / Double(labels.count) }
        var exact: Int { zip(matches, details).filter { $0.0 != nil && $0.1.isEmpty }.count }

        var summary: String {
            String(format: "RESULT %@: written %d, real %d, precision %.0f%%, found %d/%d (recall %.0f%%, reachable %d/%d), exact details %d, %.0f s",
                   title, written.count, real, precision * 100, found, labels.count, recall * 100, foundReachable, reachable, exact, seconds)
        }

        func print() {
            Swift.print("==== \(title)")
            for (i, w) in written.enumerated() {
                let tag = matches[i].map { "REAL#\($0)" + (details[i].isEmpty ? "" : " (" + details[i].joined(separator: ", ") + ")") } ?? "JUNK"
                Swift.print("  \(tag) | \(w.line)")
            }
            let missed = labels.indices.filter { !Set(matches.compactMap { $0 }).contains($0) }
            for m in missed { Swift.print("  MISSED#\(m) \(labels[m].reachable ? "" : "(unreachable) ")| \(labels[m].text)") }
            Swift.print("  footer: \(footer)")
            Swift.print(summary)
        }
    }

    static func makeBrain(projects: [(slug: String, description: String, focus: String)]) throws -> FixtureBrain {
        let brain = try FixtureBrain()
        for p in projects {
            try brain.write("projects/\(p.slug).md", """
            ---
            description: "\(p.description)"
            focus: \(p.focus)
            ---

            # \(p.slug)

            ## Now

            ## Open
            """)
        }
        return brain
    }

    static let defaultProjects: [(slug: String, description: String, focus: String)] = [
        ("alpha", "Migration of the customer data to the new platform", "Cut over the data migration in Q1"),
        ("orchid", "The reporting service and its dashboards", "Private beta in January"),
    ]

    private static func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    private static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    /// Writes the meeting as a transcript file in the format Flow produces.
    static func transcript(_ sources: [InstinctSource]) -> String {
        var out = "---\ntype: transcript\ndate: \(ymd(sources[0].time))\nstart: \"\(hhmm(sources[0].time))\"\nend: \"\(hhmm(sources.last!.time))\"\n---\n\n# Transcript\n"
        for s in sources { out += "\n**\(s.speaker?.rawValue ?? "You")** · \(hhmm(s.time))\n\(s.text)\n" }
        return out
    }

    /// A meeting sweep over `sources`, scored against `labels`.
    static func meeting(title: String, sources: [InstinctSource], labels: [Label], model: InstinctModel,
                        projects: [(slug: String, description: String, focus: String)] = defaultProjects) async throws -> Score {
        let brain = try makeBrain(projects: projects)
        let name = "\(ymd(sources[0].time)) \(hhmm(sources[0].time).replacingOccurrences(of: ":", with: "-")).md"
        try brain.write("transcripts/\(name)", transcript(sources))
        let now = sources.last!.time.addingTimeInterval(300)
        let instinct = FileManager.default.temporaryDirectory.appendingPathComponent("instinct-e2e-\(UUID().uuidString)")
        let sweep = InstinctSweep(brainRoot: brain.root, transcriptsFolder: brain.root.appendingPathComponent("transcripts"),
                                  instinctFolder: instinct, model: model, now: { now })
        let t0 = Date()
        let report = await sweep.run(kind: .meeting, transcript: brain.root.appendingPathComponent("transcripts/\(name)"), checkpoint: {})
        let seconds = Date().timeIntervalSince(t0)
        return score(title: title, report: report, labels: labels, seconds: seconds)
    }

    /// A scheduled sweep over the dictations of `InstinctGemmaFixtures.dictations`.
    static func dictations(model: InstinctModel) async throws -> Score {
        let brain = try makeBrain(projects: defaultProjects)
        let instinct = FileManager.default.temporaryDirectory.appendingPathComponent("instinct-e2e-\(UUID().uuidString)")
        let base = instinctTestDate(2026, 11, 5, 8, 0)
        for (i, d) in InstinctGemmaFixtures.dictations.enumerated() {
            let t = base.addingTimeInterval(Double(i) * 90)
            CaptureBuffer(folder: instinct, now: { t }).append(text: d.text, app: d.app, bundle: d.bundle)
        }
        let now = instinctTestDate(2026, 11, 5, 9, 0)
        let sweep = InstinctSweep(brainRoot: brain.root, transcriptsFolder: brain.root.appendingPathComponent("transcripts"),
                                  instinctFolder: instinct, model: model, now: { now })
        let t0 = Date()
        let report = await sweep.run(kind: .scheduled, transcript: nil, checkpoint: {})
        return score(title: "20 dictations", report: report, labels: InstinctGemmaFixtures.dictationLabels, seconds: Date().timeIntervalSince(t0))
    }

    static func score(title: String, report: InstinctSweepReport, labels: [Label], seconds: Double) -> Score {
        var s = Score(title: title, labels: labels, seconds: seconds)
        guard let file = report.file, let text = try? String(contentsOf: file, encoding: .utf8) else { return s }
        func norm(_ t: String) -> String { t.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("Swept ") { s.footer = line }
            guard line.hasPrefix("- [ ] "), let arrow = line.range(of: " → "), let q0 = line.range(of: " > \""),
                  let q1 = line.range(of: "\" (", options: .backwards) else { continue }
            let head = String(line[line.index(line.startIndex, offsetBy: 6)..<arrow.lowerBound])
            let category = String(head.prefix(while: { $0 != ":" }))
            let project = String(line[arrow.upperBound..<q0.lowerBound])
            let quote = String(line[q0.upperBound..<q1.lowerBound])
            let due = head.range(of: #"due: (\d{4}-\d{2}-\d{2})"#, options: .regularExpression).map { String(head[$0].suffix(10)) }
            s.written.append(Written(category: category, project: project, due: due, quote: quote, line: String(line.dropFirst(6))))
            let match = labels.indices.first { norm(labels[$0].text).contains(norm(quote)) }
            s.matches.append(match)
            var diff: [String] = []
            if let m = match {
                if labels[m].category.rawValue != category { diff.append("category \(category) != \(labels[m].category.rawValue)") }
                if (labels[m].project ?? "none") != project { diff.append("project \(project) != \(labels[m].project ?? "none")") }
                if labels[m].due != due { diff.append("due \(due ?? "-") != \(labels[m].due ?? "-")") }
            }
            s.details.append(diff)
        }
        return s
    }
}
