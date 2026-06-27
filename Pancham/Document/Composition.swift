import Foundation
import Observation

enum LineType: String, Codable, Hashable {
    case notation
    case lyric
}

/// Per-cell observable box. Giving each cell its own reference means a
/// keystroke in one cell invalidates exactly one view, not the whole grid.
@Observable
final class CellBox: Identifiable, Hashable {
    let id = UUID()
    var text: String

    init(_ text: String = "") { self.text = text }

    static func == (a: CellBox, b: CellBox) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

@Observable
final class Line: Identifiable, Codable {
    let id: UUID
    var type: LineType
    var cells: [CellBox]
    /// Optional performer's annotation for a notation line (e.g. "Sthayi 1").
    /// Empty means "use the auto line number" in the player.
    var label: String

    init(type: LineType, cells: [String], label: String = "") {
        self.id = UUID()
        self.type = type
        self.cells = cells.map { CellBox($0) }
        self.label = label
    }

    init(type: LineType, cellBoxes: [CellBox], label: String = "") {
        self.id = UUID()
        self.type = type
        self.cells = cellBoxes
        self.label = label
    }

    // Codable — serialize as { type, cells: [String], label }, accept legacy bare-array.
    enum CodingKeys: String, CodingKey { case type, cells, label }

    required convenience init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let type = try? c.decode(LineType.self, forKey: .type),
           let cells = try? c.decode([String].self, forKey: .cells) {
            let label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
            self.init(type: type, cells: cells, label: label)
            return
        }
        var u = try decoder.unkeyedContainer()
        var strs: [String] = []
        while !u.isAtEnd { strs.append(try u.decode(String.self)) }
        self.init(type: .notation, cells: strs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(cells.map { $0.text }, forKey: .cells)
        if !label.isEmpty { try c.encode(label, forKey: .label) }
    }
}

@Observable
final class CompositionSection: Identifiable, Codable {
    let id: UUID
    var name: String
    var lines: [Line]

    init(name: String = "", lines: [Line]? = nil, matras: Int = 16) {
        self.id = UUID()
        self.name = name
        self.lines = lines ?? [Line(type: .notation, cells: Array(repeating: "", count: matras))]
    }

    enum CodingKeys: String, CodingKey { case name, lines }

    required convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name  = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        let lines = (try? c.decodeIfPresent([Line].self, forKey: .lines)) ?? []
        self.init(name: name, lines: lines)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(lines, forKey: .lines)
    }
}

/// The musical form of a sheet. The "structured" forms (sargam geet, chota
/// khayal) follow a return-to-mukhda performance order; the others play through.
enum CompositionForm: String, Codable, CaseIterable, Identifiable {
    case sargamGeet
    case chotaKhayal
    case bandish
    case bollywoodSong

    var id: String { rawValue }
    var name: String {
        switch self {
        case .sargamGeet:    return "Sargam Geet"
        case .chotaKhayal:   return "Chota Khayal"
        case .bandish:       return "Bandish"
        case .bollywoodSong: return "Bollywood Song"
        }
    }
    /// Whether this form plays with the mukhda-return structure.
    var isStructured: Bool {
        switch self {
        case .sargamGeet, .chotaKhayal: return true
        case .bandish, .bollywoodSong:  return false
        }
    }
}

/// One step of a structured performance: play notation line `line` of section
/// `section`, `repeats` times. The order of steps (and re-references to the
/// mukhda) defines the return-to-refrain arc.
struct PerformanceStep: Codable, Identifiable, Hashable {
    var id: UUID
    var section: Int
    var line: Int
    var repeats: Int

    init(id: UUID = UUID(), section: Int, line: Int, repeats: Int = 1) {
        self.id = id
        self.section = section
        self.line = line
        self.repeats = max(1, repeats)
    }
}

@Observable
final class Composition: Codable {
    var title: String
    var raga: String
    var taal: TaalID
    var form: CompositionForm
    var samOffset: Int
    var laya: String
    var bpm: String
    var notes: String
    var sections: [CompositionSection]
    /// Custom performance order for structured forms. Empty = use the generated
    /// default (mukhda-return structure).
    var performance: [PerformanceStep]

    init(title: String = "",
         raga: String = "",
         taal: TaalID = .teentaal,
         form: CompositionForm = .bandish,
         samOffset: Int = 1,
         laya: String = "",
         bpm: String = "",
         notes: String = "",
         sections: [CompositionSection]? = nil,
         performance: [PerformanceStep] = []) {
        self.title = title
        self.raga = raga
        self.taal = taal
        self.form = form
        self.samOffset = samOffset
        self.laya = laya
        self.bpm = bpm
        self.notes = notes
        self.sections = sections ?? [CompositionSection(matras: taal.matras)]
        self.performance = performance
    }

    enum CodingKeys: String, CodingKey {
        case title, raga, taal, form, samOffset, laya, bpm, notes, sections, performance
    }

    required convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title:     (try? c.decodeIfPresent(String.self,  forKey: .title))     ?? "",
            raga:      (try? c.decodeIfPresent(String.self,  forKey: .raga))      ?? "",
            taal:      (try? c.decodeIfPresent(TaalID.self,  forKey: .taal))      ?? .teentaal,
            form:      (try? c.decodeIfPresent(CompositionForm.self, forKey: .form)) ?? .bandish,
            samOffset: (try? c.decodeIfPresent(Int.self,     forKey: .samOffset)) ?? 1,
            laya:      (try? c.decodeIfPresent(String.self,  forKey: .laya))      ?? "",
            bpm:       (try? c.decodeIfPresent(String.self,  forKey: .bpm))       ?? "",
            notes:     (try? c.decodeIfPresent(String.self,  forKey: .notes))     ?? "",
            sections:  (try? c.decodeIfPresent([CompositionSection].self, forKey: .sections)) ?? nil,
            performance: (try? c.decodeIfPresent([PerformanceStep].self, forKey: .performance)) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title,     forKey: .title)
        try c.encode(raga,      forKey: .raga)
        try c.encode(taal,      forKey: .taal)
        try c.encode(form,      forKey: .form)
        try c.encode(samOffset, forKey: .samOffset)
        try c.encode(laya,      forKey: .laya)
        try c.encode(bpm,       forKey: .bpm)
        try c.encode(notes,     forKey: .notes)
        try c.encode(sections,  forKey: .sections)
        if !performance.isEmpty { try c.encode(performance, forKey: .performance) }
    }
}

// MARK: - Performance structure

extension Composition {
    /// Notation-line indices (into `section.lines`) of a section, in order.
    func notationLineIndices(in section: Int) -> [Int] {
        guard sections.indices.contains(section) else { return [] }
        return sections[section].lines.enumerated()
            .filter { $0.element.type == .notation }.map { $0.offset }
    }

    /// The mukhda — the first notation line of the first section that has one.
    var mukhda: (section: Int, line: Int)? {
        for si in sections.indices {
            if let li = notationLineIndices(in: si).first { return (si, li) }
        }
        return nil
    }

    /// The default mukhda-return performance: each section's lines (its first
    /// line twice), with a return to the mukhda after every section, closing on
    /// the mukhda (Sam).
    func defaultPerformanceSteps() -> [PerformanceStep] {
        guard let mukhda else { return [] }
        var steps: [PerformanceStep] = []
        for si in sections.indices {
            let lines = notationLineIndices(in: si)
            guard !lines.isEmpty else { continue }
            for (idx, li) in lines.enumerated() {
                steps.append(PerformanceStep(section: si, line: li, repeats: idx == 0 ? 2 : 1))
            }
            steps.append(PerformanceStep(section: mukhda.section, line: mukhda.line, repeats: 1))
        }
        return steps
    }

    func isValidStep(_ s: PerformanceStep) -> Bool {
        sections.indices.contains(s.section)
            && sections[s.section].lines.indices.contains(s.line)
            && sections[s.section].lines[s.line].type == .notation
    }

    /// The step list actually in effect: the custom `performance` (valid steps
    /// only) if any, else the generated default.
    func effectivePerformanceSteps() -> [PerformanceStep] {
        let valid = performance.filter(isValidStep)
        return valid.isEmpty ? defaultPerformanceSteps() : valid
    }

    /// The ordered "rows" that a play-through visits — one per performance step
    /// (each may repeat). Structured forms use the plan; others list every
    /// notation line once. Both the audio timeline and the now-playing screen
    /// walk this, so the cursor and the karaoke rows line up.
    func performanceRows() -> [PerformanceStep] {
        if form.isStructured {
            let steps = effectivePerformanceSteps()
            if !steps.isEmpty { return steps }
        }
        return linearLineRefs().map { PerformanceStep(section: $0.section, line: $0.line, repeats: 1) }
    }

    /// The fully expanded play order — one entry per repeat, so a ×2 step becomes
    /// two consecutive units. Both the audio timeline and the now-playing rows
    /// walk this, so repeats show as duplicated lines that play linearly.
    func performanceUnits() -> [(section: Int, line: Int)] {
        var units: [(section: Int, line: Int)] = []
        for row in performanceRows() {
            for _ in 0..<max(1, row.repeats) { units.append((row.section, row.line)) }
        }
        return units
    }

    func linearLineRefs() -> [(section: Int, line: Int)] {
        var refs: [(section: Int, line: Int)] = []
        for si in sections.indices {
            for li in notationLineIndices(in: si) { refs.append((si, li)) }
        }
        return refs
    }
}

extension Composition {
    var matras: Int { taal.matras }

    /// Ensure every line has exactly `matras` cells. Pads with empties or truncates.
    func normalize() {
        let m = matras
        for s in sections {
            for l in s.lines {
                if l.cells.count < m {
                    l.cells.append(contentsOf: (l.cells.count..<m).map { _ in CellBox() })
                } else if l.cells.count > m {
                    l.cells = Array(l.cells.prefix(m))
                }
            }
            if s.lines.isEmpty {
                s.lines = [Line(type: .notation, cells: Array(repeating: "", count: m))]
            }
        }
        if sections.isEmpty {
            sections = [CompositionSection(matras: m)]
        }
    }
}
