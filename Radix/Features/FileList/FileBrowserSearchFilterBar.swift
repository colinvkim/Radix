import SwiftUI

struct FileBrowserSearchFilterBar: View {
    @Binding var scope: FileBrowserFindTarget
    @Binding var text: String
    let isLoading: Bool
    @FocusState.Binding var isFocused: Bool

    private var scopeLabel: String {
        switch scope {
        case .currentContents:
            "Current Contents"
        case .entireScan:
            "Entire Scan"
        }
    }

    private var prompt: String {
        switch scope {
        case .currentContents:
            "Filter current contents"
        case .entireScan:
            "Search entire scan"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Current Contents") {
                    scope = .currentContents
                    isFocused = true
                }

                Button("Entire Scan") {
                    scope = .entireScan
                    isFocused = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: scope == .currentContents ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                    Text(scopeLabel)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(scope == .currentContents ? "Clear current contents filter" : "Clear entire scan search")
                .accessibilityLabel(scope == .currentContents ? "Clear current contents filter" : "Clear entire scan search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .controlSize(.small)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}
