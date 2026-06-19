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

    init(type: LineType, cells: [String]) {
        self.id = UUID()
        self.type = type
        self.cells = cells.map { CellBox($0) }
    }

    init(type: LineType, cellBoxes: [CellBox]) {
        self.id = UUID()
        self.type = type
        self.cells = cellBoxes
    }

    // Codable — serialize as { type, cells: [String] }, accept legacy bare-array.
    enum CodingKeys: String, CodingKey { case type, cells }

    required convenience init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let type = try? c.decode(LineType.self, forKey: .type),
           let cells = try? c.decode([String].self, forKey: .cells) {
            self.init(type: type, cells: cells)
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

@Observable
final class Composition: Codable {
    var title: String
    var raga: String
    var taal: TaalID
    var samOffset: Int
    var laya: String
    var bpm: String
    var notes: String
    var sections: [CompositionSection]

    init(title: String = "",
         raga: String = "",
         taal: TaalID = .teentaal,
         samOffset: Int = 1,
         laya: String = "",
         bpm: String = "",
         notes: String = "",
         sections: [CompositionSection]? = nil) {
        self.title = title
        self.raga = raga
        self.taal = taal
        self.samOffset = samOffset
        self.laya = laya
        self.bpm = bpm
        self.notes = notes
        self.sections = sections ?? [CompositionSection(matras: taal.matras)]
    }

    enum CodingKeys: String, CodingKey {
        case title, raga, taal, samOffset, laya, bpm, notes, sections
    }

    required convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title:     (try? c.decodeIfPresent(String.self,  forKey: .title))     ?? "",
            raga:      (try? c.decodeIfPresent(String.self,  forKey: .raga))      ?? "",
            taal:      (try? c.decodeIfPresent(TaalID.self,  forKey: .taal))      ?? .teentaal,
            samOffset: (try? c.decodeIfPresent(Int.self,     forKey: .samOffset)) ?? 1,
            laya:      (try? c.decodeIfPresent(String.self,  forKey: .laya))      ?? "",
            bpm:       (try? c.decodeIfPresent(String.self,  forKey: .bpm))       ?? "",
            notes:     (try? c.decodeIfPresent(String.self,  forKey: .notes))     ?? "",
            sections:  (try? c.decodeIfPresent([CompositionSection].self, forKey: .sections)) ?? nil
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title,     forKey: .title)
        try c.encode(raga,      forKey: .raga)
        try c.encode(taal,      forKey: .taal)
        try c.encode(samOffset, forKey: .samOffset)
        try c.encode(laya,      forKey: .laya)
        try c.encode(bpm,       forKey: .bpm)
        try c.encode(notes,     forKey: .notes)
        try c.encode(sections,  forKey: .sections)
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
