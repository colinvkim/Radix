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
        VStack(spacing: 0) {
            pathHeader
            Divider()
            if showsError {
                Text("This path is not available in the current scan.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(completions) { node in
                        Button {
                            accept(node)
                        } label: {
                            breadcrumbLabel(for: node)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(selectedCompletionID == node.id ? Color.accentColor.opacity(0.18) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .highPriorityGesture(
                            TapGesture(count: 2)
                                .exclusively(before: TapGesture(count: 1))
                                .onEnded { activation in
                                    guard !isSubmitting else { return }
                                    switch activation {
                                    case .first:
                                        navigate(to: node)
                                    case .second:
                                        accept(node)
                                    }
                                }
                        )
                        .accessibilityLabel(Text(verbatim: ScanPathResolver.completionPath(for: node)))
                        .accessibilityAddTraits(selectedCompletionID == node.id ? .isSelected : [])
                        .accessibilityAction(named: Text("Go to Path")) {
                            navigate(to: node)
                        }
                        .help(ScanPathResolver.completionPath(for: node))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
        }
        .frame(width: 520)
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

    private var pathHeader: some View {
        HStack(spacing: 10) {
            TextField("Go to Path", text: $path)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isPathFocused)
                .accessibilityLabel("Path")
                .accessibilityAction(named: Text("Go to Path")) { submit() }
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
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel")
            .help("Cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func breadcrumbLabel(for node: FileNodeRecord) -> some View {
        let components = node.url.pathComponents.filter { $0 != "/" }
        let ancestors = components.dropLast().joined(separator: " › ")
        return HStack(spacing: 6) {
            if !ancestors.isEmpty {
                Text(verbatim: ancestors)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(verbatim: components.last ?? node.url.path)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
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

    private func navigate(to node: FileNodeRecord) {
        guard !isSubmitting else { return }
        accept(node)
        submit()
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
