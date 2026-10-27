import SwiftUI

struct GoToPathSheet: View {
    let resolver: ScanPathResolver
    let onCancel: () -> Void
    let onGo: (String) async -> Bool

    @State private var path: String
    @State private var completions: [FileNodeRecord] = []
    @State private var selectedCompletionID: FileNodeRecord.ID?
    @State private var showsError = false
    @State private var submissionTask: Task<Void, Never>?
    @FocusState private var isPathFocused: Bool

    init(resolver: ScanPathResolver, onCancel: @escaping () -> Void, onGo: @escaping (String) async -> Bool) {
        self.resolver = resolver
        self.onCancel = onCancel
        self.onGo = onGo
        _path = State(initialValue: resolver.initialPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Path")
                .font(.headline)
            Text("Enter a path in this scan.")
                .foregroundStyle(.secondary)
            TextField("Path", text: $path)
                .textFieldStyle(.roundedBorder)
                .focused($isPathFocused)
                .accessibilityLabel("Path")
                .disabled(isSubmitting)
                .onSubmit { submit() }
                .onKeyPress(.downArrow) { moveSelection(by: 1) }
                .onKeyPress(.upArrow) { moveSelection(by: -1) }
                .onKeyPress(.tab, phases: .down) { press in
                    guard press.modifiers.isEmpty, let completion = selectedCompletion ?? completions.first else {
                        return .ignored
                    }
                    accept(completion)
                    return .handled
                }
            if !completions.isEmpty {
                VStack(spacing: 2) {
                    ForEach(completions) { node in
                        Button {
                            accept(node)
                        } label: {
                            Label {
                                Text(verbatim: ScanPathResolver.completionPath(for: node))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: node.systemImageName)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(selectedCompletionID == node.id ? Color.accentColor.opacity(0.18) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedCompletionID == node.id ? .isSelected : [])
                    }
                }
                .disabled(isSubmitting)
            }
            if showsError {
                Text("This path is not available in the current scan.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Go") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onDisappear { submissionTask?.cancel() }
        .task { isPathFocused = true }
        .task(id: path) {
            showsError = false
            selectedCompletionID = nil
            completions = []
            let input = path
            let resolver = resolver
            let query = Task.detached(priority: .userInitiated) {
                try resolver.completions(for: input, cancellationCheck: { try Task.checkCancellation() })
            }
            let matches = await withTaskCancellationHandler {
                try? await query.value
            } onCancel: {
                query.cancel()
            }
            guard !Task.isCancelled, path == input else { return }
            completions = matches ?? []
        }
    }

    private var isSubmitting: Bool { submissionTask != nil }

    private var selectedCompletion: FileNodeRecord? {
        completions.first { $0.id == selectedCompletionID }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard !completions.isEmpty else { return .ignored }
        let index = selectedCompletionID.flatMap { id in completions.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + offset, 0), completions.count - 1) }
            ?? (offset > 0 ? 0 : completions.count - 1)
        selectedCompletionID = completions[next].id
        return .handled
    }

    private func accept(_ node: FileNodeRecord) {
        path = ScanPathResolver.completionPath(for: node)
        selectedCompletionID = nil
        isPathFocused = true
    }

    private func submit() {
        guard !isSubmitting else { return }
        let input = selectedCompletion.map(ScanPathResolver.completionPath) ?? path
        submissionTask = Task { @MainActor in
            let succeeded = await onGo(input)
            submissionTask = nil
            guard !Task.isCancelled else { return }
            showsError = !succeeded
            if !succeeded { isPathFocused = true }
        }
    }
}
