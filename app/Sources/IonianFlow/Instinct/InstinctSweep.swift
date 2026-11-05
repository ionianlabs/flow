import Foundation

struct InstinctSweepReport: Equatable {
    var dropped = InstinctDropCounts()
    var written = 0
    var file: URL?
    var capReached = false
    var failed = false
}

/// One sweep over the buffer and the finished transcripts (spec F1.12 to F1.34). Everything it touches is injected.
struct InstinctSweep {
    var brainRoot: URL
    var transcriptsFolder: URL
    var instinctFolder: URL
    var model: InstinctModel
    var now: () -> Date = Date.init
    var timeZone: TimeZone = .current

    func run(kind: InstinctSweepKind, transcript: URL?, checkpoint: () async -> Void) async -> InstinctSweepReport {
        var report = InstinctSweepReport()
        guard BrainLines.isBrain(brainRoot) else { report.failed = true; return report }

        // Sources.
        let buffer = CaptureBuffer(folder: instinctFolder, now: now)
        let state = InstinctState.load(from: instinctFolder)
        let pending = TranscriptSource.pending(in: transcriptsFolder, state: state, timeZone: timeZone)
        var sources: [InstinctSource] = []
        var read: [CaptureBuffer.Entry] = []
        var transcriptFiles: [URL] = []
        var recordAsSwept: [String] = []
        switch kind {
        case .scheduled:
            read = buffer.read()
            for e in read {
                if InstinctRules.prefilter(text: e.text, bundle: e.bundle) != nil {
                    report.dropped.byRules += 1
                } else {
                    sources.append(InstinctSource(id: e.id, kind: .dictation(app: e.app, bundle: e.bundle), time: e.time,
                                                  speaker: nil, text: e.text))
                }
            }
            transcriptFiles = pending.toRead
            recordAsSwept = pending.recordAsSwept
        case .meeting:
            guard let transcript, pending.toRead.contains(where: { $0.lastPathComponent == transcript.lastPathComponent }) else { return report }
            transcriptFiles = [transcript]
        }
        let transcriptSources = transcriptFiles.flatMap { TranscriptSource.parse(fileURL: $0, timeZone: timeZone) }
        sources = transcriptSources + sources

        // Extract and validate.
        let projects = BrainLines.projects(in: brainRoot)
        let hints = projects.map { InstinctProjectHint(slug: $0.slug, description: $0.description, focus: $0.focus) }
        let writer = InstinctWriter(brainRoot: brainRoot, transcriptsFolder: transcriptsFolder, timeZone: timeZone)
        let remaining = max(InstinctRules.perDayCap - writer.itemsToday(on: now()), 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let brainLines = BrainLines.lines(in: brainRoot, now: now(), calendar: calendar)
        let dedup = InstinctDedup(model: model)
        var entries: [InstinctWriter.Entry] = []
        for chunk in remaining == 0 ? [] : Self.chunks(sources) {
            var answer: [InstinctItem]?
            for _ in 0..<2 where answer == nil {   // one retry (F1.32)
                await checkpoint()
                answer = try? await model.extract(chunk, projects: hints)
            }
            guard let items = answer else { report.dropped.unreadable += 1; continue }
            for var item in items {
                guard let source = chunk.first(where: { $0.id == item.sourceID }),
                      InstinctParsing.isVerbatim(item.quote, in: source.text) else { report.dropped.quoteNotFound += 1; continue }
                if !projects.contains(where: { $0.slug == item.project }) { item.project = "none" }
                item.due = InstinctRules.rolledDue(item.due, quote: item.quote, sourceTime: source.time, calendar: calendar)
                if let reason = InstinctRules.gate(kind: item.category.rawValue, project: item.project, confidence: item.confidence) {
                    if reason == .noProject { report.dropped.noProject += 1 } else { report.dropped.lowConfidence += 1 }
                    continue
                }
                // Evidence in the quote itself: the mechanical test of the extract prompt, applied in code.
                guard InstinctRules.hasEvidence(kind: item.category.rawValue, quote: item.quote) else { report.dropped.byRules += 1; continue }
                // Verification: a strict second look. An error keeps nothing and counts as low confidence.
                await checkpoint()
                guard let check = try? await model.verify(item, speaker: source.speaker, project: hints.first { $0.slug == item.project }),
                      check.holds else { report.dropped.lowConfidence += 1; continue }
                if !check.belongsToProject, item.project != "none" {
                    item.project = "none"
                    if InstinctRules.gate(kind: item.category.rawValue, project: item.project, confidence: item.confidence) != nil {
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

        // Cut (F1.27, F1.28).
        report.capReached = remaining == 0
        let cut = InstinctRules.keepHighestConfidence(entries, limit: min(InstinctRules.perSweepCap, remaining)) { $0.item.confidence }
        entries = cut.kept
        report.dropped.belowCut = cut.cut

        // Write, then state, then buffer (F1.33).
        do {
            report.file = try writer.write(at: now(), kind: kind, entries: entries, meetings: transcriptFiles.count,
                                           dictations: read.count, dropped: report.dropped)
            var newState = InstinctState.load(from: instinctFolder)
            for name in transcriptFiles.map(\.lastPathComponent) + recordAsSwept {
                newState.swept.append(name)
            }
            try newState.save(to: instinctFolder)
        } catch {
            return InstinctSweepReport(failed: true)
        }
        buffer.remove(ids: Set(read.map(\.id)))
        report.written = report.file == nil ? 0 : entries.count
        return report
    }

    /// The parts the model reads. Meeting blocks come first in parts of `InstinctRules.chunkLimit` characters and
    /// `chunkMaxSources` sources at most; a dictation is its own part (a small model skips items when it reads several unrelated snippets at once).
    static func chunks(_ sources: [InstinctSource]) -> [[InstinctSource]] {
        func isDictation(_ s: InstinctSource) -> Bool { if case .dictation = s.kind { return true } else { return false } }
        return InstinctRules.chunks(sources.filter { !isDictation($0) })
            + InstinctRules.chunks(sources.filter(isDictation), maxSources: InstinctRules.dictationMaxSources)
    }
}
