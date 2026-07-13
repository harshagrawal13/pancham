import SwiftUI

/// Edits the return-to-mukhda performance order for structured forms (chota
/// khayal / sargam geet): an ordered, reorderable list of steps, each playing a
/// notation line a number of times. Opening it materializes the generated
/// default so there's always something to edit.
struct PerformanceEditorView: View {
    @Bindable var composition: Composition
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(Array(composition.performance.enumerated()), id: \.element.id) { idx, step in
                    stepRow(idx, step)
                }
                .onMove { composition.performance.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { composition.performance.remove(atOffsets: $0) }
            }
            .listStyle(.inset)
            footer
        }
        .frame(width: 480, height: 540)
        .background(Theme.paper)
        .onAppear {
            if composition.performance.isEmpty {
                composition.performance = composition.defaultPerformanceSteps()
            }
        }
    }

    // MARK: Bars

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Performance")
                    .font(Theme.display(20, weight: .medium)).foregroundStyle(Theme.ink)
                Text("\(composition.form.name) · order of singing")
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Done", action: onClose).buttonStyle(FilledButtonStyle())
        }
        .padding(18)
    }

    private var footer: some View {
        HStack {
            Menu {
                ForEach(Array(addOptions.enumerated()), id: \.offset) { _, opt in
                    Button(optionLabel(opt)) {
                        composition.performance.append(PerformanceStep(section: opt.s, line: opt.l))
                    }
                }
            } label: {
                Label("Add line", systemImage: "plus")
            }
            .menuStyle(.borderlessButton).fixedSize()

            Spacer()

            Button("Reset to default") {
                composition.performance = composition.defaultPerformanceSteps()
            }
            .buttonStyle(ToolbarOutlineButton())
        }
        .padding(14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ruleFaint).frame(height: 1) }
    }

    // MARK: Row

    private func stepRow(_ idx: Int, _ step: PerformanceStep) -> some View {
        HStack(spacing: 10) {
            Text("\(idx + 1).")
                .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                .frame(width: 26, alignment: .trailing)
            Text(label(idx, step))
                .font(Theme.ui(13)).foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer()
            Stepper("×\(repeats(step))", value: repeatsBinding(step), in: 1...8)
                .fixedSize()
            Button { composition.performance.removeAll { $0.id == step.id } } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 2)
    }

    // MARK: Helpers

    private func label(_ idx: Int, _ step: PerformanceStep) -> String {
        guard composition.isValidStep(step) else { return "— (removed line)" }
        let raw = composition.sections[step.section].name
        let name = raw.isEmpty ? "Section \(step.section + 1)" : raw
        let nIdx = composition.notationLineIndices(in: step.section)
        let num = (nIdx.firstIndex(of: step.line) ?? 0) + 1
        let isMukhda = composition.mukhda.map { $0.section == step.section && $0.line == step.line } ?? false
        if isMukhda { return idx == 0 ? "\(name) \(num) · mukhda" : "↩ Mukhda" }
        return "\(name) \(num)"
    }

    private func repeats(_ step: PerformanceStep) -> Int {
        composition.performance.first { $0.id == step.id }?.repeats ?? 1
    }

    private func repeatsBinding(_ step: PerformanceStep) -> Binding<Int> {
        Binding(
            get: { repeats(step) },
            set: { v in
                if let i = composition.performance.firstIndex(where: { $0.id == step.id }) {
                    composition.performance[i].repeats = max(1, v)
                }
            })
    }

    private var addOptions: [(s: Int, l: Int)] {
        var out: [(s: Int, l: Int)] = []
        for si in composition.sections.indices {
            for li in composition.notationLineIndices(in: si) { out.append((si, li)) }
        }
        return out
    }

    private func optionLabel(_ opt: (s: Int, l: Int)) -> String {
        let raw = composition.sections[opt.s].name
        let name = raw.isEmpty ? "Section \(opt.s + 1)" : raw
        let num = (composition.notationLineIndices(in: opt.s).firstIndex(of: opt.l) ?? 0) + 1
        return "\(name) \(num)"
    }
}
