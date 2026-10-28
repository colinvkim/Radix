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
    @State private var focusRequest = UUID()

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
        .onExitCommand(perform: onCancel)
        .onDisappear { submissionTask?.cancel() }
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
            NativePathField(text: editedPath, focusRequest: focusRequest, onCommand: handleInputCommand)
                .frame(maxWidth: .infinity)
                .accessibilityAction(named: Text("Go to Path")) { submit() }
                .disabled(isSubmitting)
            Button(action: clearOrCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(path.isEmpty ? Text("Cancel") : Text("Clear"))
            .help(path.isEmpty ? Text("Cancel") : Text("Clear"))
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

    private func handleInputCommand(_ command: NativePathField.Command) -> Bool {
        switch command {
        case let .moveSelection(offset):
            return moveSelection(by: offset)
        case .complete:
            guard let completion = selectedCompletion ?? completions.first else { return false }
            accept(completion)
            return true
        case .submit:
            submit()
            return true
        case .cancel:
            onCancel()
            return true
        }
    }

    private func moveSelection(by offset: Int) -> Bool {
        guard !completions.isEmpty else { return false }
        let index = selectedCompletionID.flatMap { id in completions.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + offset, 0), completions.count - 1) }
            ?? (offset > 0 ? 0 : completions.count - 1)
        selectedCompletionID = completions[next].id
        return true
    }

    private func accept(_ node: FileNodeRecord) {
        path = ScanPathResolver.completionPath(for: node)
        selectedCompletionID = node.id
        focusRequest = UUID()
    }

    private func clearOrCancel() {
        guard !path.isEmpty else { onCancel(); return }
        submissionTask?.cancel()
        path = ""
        selectedCompletionID = nil
        completions = []
        showsError = false
        focusRequest = UUID()
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
            if !succeeded { focusRequest = UUID() }
        }
    }
}

private struct NativePathField: NSViewRepresentable {
    enum Command {
        case moveSelection(Int)
        case complete
        case submit
        case cancel
    }

    @Binding var text: String
    let focusRequest: UUID
    let onCommand: (Command) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.stringValue = text
        field.placeholderString = String(localized: "Go to Path")
        field.font = .preferredFont(forTextStyle: .title3)
        field.textColor = .labelColor
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(String(localized: "Path"))
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        context.coordinator.update(field)
    }

    final class Field: NSTextField {
        private var pendingFocus = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { window.initialFirstResponder = self }
            focusIfRequested()
        }

        func requestFocus() { pendingFocus = true }

        func focusIfRequested() {
            guard pendingFocus, isEnabled, let window else { return }
            pendingFocus = !window.makeFirstResponder(self)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativePathField
        private var appliedRequest: UUID?
        private var applyingEdit = false

        init(parent: NativePathField) { self.parent = parent }

        func update(_ field: Field) {
            let hasRequest = appliedRequest != parent.focusRequest
            if hasRequest { field.requestFocus() }
            field.focusIfRequested()
            guard let editor = field.currentEditor() as? NSTextView else {
                field.stringValue = parent.text
                appliedRequest = parent.focusRequest
                return
            }
            guard hasRequest else { return }
            guard editor.string != parent.text else {
                appliedRequest = parent.focusRequest
                return
            }
            applyingEdit = true
            defer { applyingEdit = false }
            editor.breakUndoCoalescing()
            if editor.hasMarkedText() {
                editor.inputContext?.discardMarkedText()
                editor.unmarkText()
            }
            let previous = editor.string
            let prefixCount = zip(previous, parent.text).prefix { $0.0 == $0.1 }.count
            let prefixLength = previous.prefix(prefixCount).utf16.count
            let replacement = String(parent.text.dropFirst(prefixCount))
            let range = NSRange(location: prefixLength, length: previous.utf16.count - prefixLength)
            let attributed = NSAttributedString(string: replacement, attributes: editor.typingAttributes)
            if editor.performValidatedReplacement(in: range, with: attributed) {
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                appliedRequest = parent.focusRequest
            }
            editor.breakUndoCoalescing()
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.allowsUndo = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !applyingEdit, let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCommand(.moveSelection(-1))
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCommand(.moveSelection(1))
            case #selector(NSResponder.insertTab(_:)):
                return parent.onCommand(.complete)
            case #selector(NSResponder.insertNewline(_:)):
                return parent.onCommand(.submit)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCommand(.cancel)
            default:
                return false
            }
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
