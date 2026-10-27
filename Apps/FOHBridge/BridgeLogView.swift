import AppKit
import SwiftUI
import FOHMacKit

struct BridgeLogView: View {
    let server: BridgeServer

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(server.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: server.logLines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            Divider()
            HStack {
                Text("\(server.logLines.count) lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.logLines.joined(separator: "\n"), forType: .string)
                }
            }
            .padding(8)
        }
    }
}
