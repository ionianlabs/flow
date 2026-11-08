import Foundation

struct AwareSweepReport: Equatable {
    var dropped = AwareDropCounts()
    var written = 0
    var file: URL?
    var capReached = false
    var failed = false
}

/// One sweep over the finished transcripts (spec F1.12 to F1.34, F1.42). Everything it touches is injected.
struct AwareSweep {
    var brainRoot: URL
    var transcriptsFolder: URL
    var awareFolder: URL
    var model: AwareModel
    var now: () -> Date = Date.init
    var timeZone: TimeZone = .current
    /// What the Aware page lets through (F3.5 to F3.7).
    var kinds: Set<AwareCategory> = Set(AwareCategory.allCases)

    func run(kind: AwareSweepKind, transcript: URL?, checkpoint: () async -> Void) async -> AwareSweepReport {
        var report = AwareSweepReport()
        guard BrainLines.isBrain(brainRoot) else { report.failed = true; return report }

        // Sources.
        let state = AwareState.load(from: awareFolder)
        let pending = TranscriptSource.pending(in: transcriptsFolder, state: state, timeZone: timeZone)
        var transcriptFiles: [URL] = []
        var recordAsSwept: [String] = []
        switch kind {
        case .catchUp:
            transcriptFiles = pending.toRead
            recordAsSwept = pending.recordAsSwept
        case .meeting:
            guard let transcript, pending.toRead.contains(where: { $0.lastPathComponent == transcript.lastPathComponent }) else { return report }
            transcriptFiles = [transcript]
        }
        let sources = transcriptFiles.flatMap { TranscriptSource.parse(fileURL: $0, timeZone: timeZone) }

        // Extract and validate.
        let projects = BrainLines.projects(in: brainRoot)
        let hints = projects.map { AwareProjectHint(slug: $0.slug, description: $0.description, focus: $0.focus) }
        let writer = AwareWriter(brainRoot: brainRoot, transcriptsFolder: transcriptsFolder, timeZone: timeZone)
        let remaining = max(AwareRules.perDayCap - writer.itemsToday(on: now()), 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let brainLines = BrainLines.lines(in: brainRoot, now: now(), calendar: calendar)
        let dedup = AwareDedup(model: model)
        var entries: [AwareWriter.Entry] = []
        let parts = remaining == 0 ? [] : Self.chunks(sources)
        for chunk in parts {
            var answer: [AwareItem]?
            for _ in 0..<2 where answer == nil {   // one retry (F1.32)
                await checkpoint()
                do { answer = try await model.extract(chunk, projects: hints) } catch { NSLog("Ionian Flow: Aware model failed: %@", Self.safeDescription(error)) }
            }
            guard let items = answer else { report.dropped.unreadable += 1; continue }
            for var item in items {
                guard let source = chunk.first(where: { $0.id == item.sourceID }),
                      AwareParsing.isVerbatim(item.quote, in: source.text) else { report.dropped.quoteNotFound += 1; continue }
                // F3.5: a kind the user switched off is dropped here, before the verification call.
                guard kinds.contains(item.category) else { report.dropped.byRules += 1; continue }
                if !projects.contains(where: { $0.slug == item.project }) { item.project = "none" }
                if item.category == .todo {
                    item.due = AwareRules.weekdayDue(item.due, quote: item.quote, sourceTime: source.time, calendar: calendar)
                }
                item.due = AwareRules.rolledDue(item.due, quote: item.quote, sourceTime: source.time, calendar: calendar)
                if let reason = AwareRules.gate(kind: item.category.rawValue, project: item.project, confidence: item.confidence) {
                    if reason == .noProject { report.dropped.noProject += 1 } else { report.dropped.lowConfidence += 1 }
                    continue
                }
                // Evidence in the quote itself: the mechanical test of the extract prompt, applied in code.
                guard AwareRules.hasEvidence(kind: item.category.rawValue, quote: item.quote) else { report.dropped.byRules += 1; continue }
                // Verification: a strict second look. An error keeps nothing and counts as low confidence.
                await checkpoint()
                guard let check = try? await model.verify(item, speaker: source.speaker, project: hints.first { $0.slug == item.project }),
                      check.holds else { report.dropped.lowConfidence += 1; continue }
                if !check.belongsToProject, item.project != "none" {
                    item.project = "none"
                    if AwareRules.gate(kind: item.category.rawValue, project: item.project, confidence: item.confidence) != nil {
                        report.dropped.noProject += 1; continue
                    }
                }
                await checkpoint()
                switch await dedup.check(item, against: brainLines, earlier: entries.map(\.item)) {
                case .duplicate: report.dropped.duplicate += 1
                case .keep(let kept): entries.append(.init(item: kept, source: source))
                }
            }
        }

        // F1.38: not one part could be read, so the model is the problem, not the content. Keep everything for the next sweep.
        if !parts.isEmpty, report.dropped.unreadable == parts.count {
            var failed = AwareState.load(from: awareFolder)
            failed.lastResult = AwareSweepResult(at: now(), meetings: transcriptFiles.count, written: 0, failed: true)
            try? failed.save(to: awareFolder)
            report.failed = true
            return report
        }

        // Cut (F1.27, F1.28).
        report.capReached = remaining == 0
        let cut = AwareRules.keepHighestConfidence(entries, limit: min(AwareRules.perSweepCap, remaining)) { $0.item.confidence }
        entries = cut.kept
        report.dropped.belowCut = cut.cut

        // Write, then state (F1.33).
        do {
            report.file = try writer.write(at: now(), kind: kind, entries: entries, meetings: transcriptFiles.count,
                                           dropped: report.dropped)
            var newState = AwareState.load(from: awareFolder)
            for name in transcriptFiles.map(\.lastPathComponent) + recordAsSwept {
                newState.swept.append(name)
            }
            newState.lastResult = AwareSweepResult(at: now(), meetings: transcriptFiles.count,
                                                      written: report.file == nil ? 0 : entries.count, file: report.file?.path)
            try newState.save(to: awareFolder)
        } catch {
            return AwareSweepReport(failed: true)
        }
        let d = report.dropped
        NSLog("Ionian Flow: Aware dropped: %d rules, %d no project, %d low confidence, %d duplicate, %d quote not found, %d unreadable, %d below the cut",
              d.byRules, d.noProject, d.lowConfidence, d.duplicate, d.quoteNotFound, d.unreadable, d.belowCut)
        report.written = report.file == nil ? 0 : entries.count
        return report
    }

    /// An error for the log: never the model's answer, which quotes what the user said.
    static func safeDescription(_ error: Error) -> String {
        if case AwareModelError.unparsable = error { return "answer did not parse" }
        return String(describing: type(of: error))
    }

    /// The parts the model reads: meeting blocks in order, in parts of `AwareRules.chunkLimit` characters and
    /// `chunkMaxSources` sources at most.
    static func chunks(_ sources: [AwareSource]) -> [[AwareSource]] { AwareRules.chunks(sources) }
}
