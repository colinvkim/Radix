import AppKit
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
            ScrollViewReader { proxy in
                List(selection: $selectedCompletionID) {
                    ForEach(completions) { node in
                        Button {
                            accept(node)
                        } label: {
                            breadcrumbLabel(for: node)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                        .tag(node.id)
                        .id(node.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            selectedCompletionID == node.id
                                ? PathSelectionMaterial()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .padding(.horizontal, 10)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                : nil
                        )
                        .accessibilityLabel(Text(verbatim: ScanPathResolver.completionPath(for: node)))
                        .accessibilityAction(named: Text("Go to Path")) {
                            navigate(to: node)
                        }
                        .help(ScanPathResolver.completionPath(for: node))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedCompletionID) { _, nodeID in
                    if let nodeID { proxy.scrollTo(nodeID) }
                }
            }
            .frame(height: 212)
        }
        .frame(width: 520)
        .onDisappear { submissionTask?.cancel() }
        .task { isPathFocused = true }
        .task(id: path) {
            showsError = false
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
            if let selectedCompletionID,
               !completions.contains(where: { $0.id == selectedCompletionID }) {
                self.selectedCompletionID = nil
            }
        }
    }

    private var editedPath: Binding<String> {
        Binding(
            get: { path },
            set: { input in
                guard path != input else { return }
                path = input
                selectedCompletionID = nil
                completions = []
            }
        )
    }

    private var pathHeader: some View {
        HStack(spacing: 10) {
            TextField("Go to Path", text: editedPath)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isPathFocused)
                .accessibilityLabel("Path")
                .accessibilityAction(named: Text("Go to Path")) { submit() }
                .disabled(isSubmitting)
                .onSubmit { submit() }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                    guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
                        return .ignored
                    }
                    return moveSelection(by: 1)
                }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                    guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
                        return .ignored
                    }
                    return moveSelection(by: -1)
                }
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
                Group {
                    if selectedCompletionID == node.id {
                        Text(verbatim: ancestors)
                    } else {
                        Text(verbatim: ancestors)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.head)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(verbatim: components.last ?? node.url.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .foregroundStyle(CompletionForeground(isSelected: selectedCompletionID == node.id))
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
        selectedCompletionID = node.id
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

private struct PathSelectionMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.isEmphasized = context.environment.pathSelectionAppearsActive
    }
}

private struct CompletionForeground: ShapeStyle {
    let isSelected: Bool

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        guard isSelected else { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(Color(nsColor: environment.pathSelectionAppearsActive
            ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor))
    }
}

private extension EnvironmentValues {
    nonisolated var pathSelectionAppearsActive: Bool {
        if #available(macOS 15.0, *) {
            appearsActive
        } else {
            controlActiveState != .inactive
        }
    }
}
