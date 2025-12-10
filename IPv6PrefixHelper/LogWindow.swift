import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LogWindow: View {
    @ObservedObject var viewModel: IPv6PrefixViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Titelzeile mit Aktionen
            HStack {
                Text(NSLocalizedString("Debug-Log", comment: "Log window title"))
                    .font(.headline)

                Spacer()

                Button(NSLocalizedString("Exportieren …", comment: "Export log button")) {
                    exportLog()
                }

                Button(NSLocalizedString("Leeren", comment: "Clear log button")) {
                    viewModel.clearLog()
                }
            }
            .padding()

            Divider()

            // Scrollbarer Logbereich – neueste Einträge oben
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.logEntries.enumerated().reversed()), id: \.element.id) { (_, entry) in
                        let (timestampPart, messagePart) = splitLogLine(entry.text)
                        let lineColor = color(for: entry.text)

                        HStack(alignment: .top, spacing: 4) {
                            Text(timestampPart)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(lineColor)

                            Text(messagePart)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(lineColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 950, height: 450)
    }

    // Farbwahl je nach Inhalt (heuristisch)
    private func color(for text: String) -> Color {
        let lower = text.lowercased()

        // Spezielle Hervorhebung für den Route-/NWPath-Monitor
        if lower.contains("nwpathmonitor") || lower.contains("route-monitor") {
            return Color.blue.opacity(0.85)
        }

        // Klar erkennbare Auto-Fix-/Reparatur-Einträge
        if lower.contains("auto-fix") || lower.contains("ipv6-fix") || lower.contains("konfiguration neu gesetzt") || lower.contains("ipv6-konfiguration wurde erneuert") {
            return Color.orange.opacity(0.9)
        }

        if lower.contains("fehler") || lower.contains("error") {
            return Color.red.opacity(0.85)
        } else if lower.contains("warnung") || lower.contains("warning") {
            return Color.yellow.opacity(0.9)
        } else if lower.contains("alles in ordnung") || lower.contains("ok") {
            return Color.green.opacity(0.85)
        }

        return .primary
    }

    private func splitLogLine(_ fullText: String) -> (String, String) {
        let parts = fullText.split(separator: "]", maxSplits: 1, omittingEmptySubsequences: false)

        if let first = parts.first {
            let timestamp = String(first) + "]"
            let message: String
            if parts.count > 1 {
                message = String(parts[1]).trimmingCharacters(in: .whitespaces)
            } else {
                message = ""
            }
            return (timestamp, message)
        } else {
            return (fullText, "")
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Log exportieren", comment: "Save panel title")
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = NSLocalizedString("IPv6PrefixHelper-Log.txt", comment: "Default log filename")

        if panel.runModal() == .OK, let url = panel.url {
            let text = viewModel.logEntries.map { $0.text }.joined(separator: "\n")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Fehler beim Schreiben der Logdatei: \(error)")
            }
        }
    }
}
