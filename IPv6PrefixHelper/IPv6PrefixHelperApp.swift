import SwiftUI
import AppKit
import Combine

@main
struct IPv6PrefixHelperApp: App {
    @StateObject private var viewModel: IPv6PrefixViewModel
    @State private var logWindow: NSWindow?

    private var preferredColorScheme: ColorScheme? {
        switch viewModel.appearanceMode {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil   // Systemstandard
        }
    }

    init() {
        // --- System-Sprachen aus der Global-Domain holen ---
        // Entspricht `defaults read -g AppleLanguages`
        let globalDomain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let globalAppleLanguages = (globalDomain?["AppleLanguages"] as? [String]) ?? []

        // App-spezifische Override-Defaults auf Systemwerte setzen,
        // damit alte Reste von unserem früheren Sprachumschalter verschwinden.
        if !globalAppleLanguages.isEmpty {
            UserDefaults.standard.set(globalAppleLanguages, forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        } else {
            // Sicherheitslog – sollte bei dir nicht auftreten
            print("⚠️ Keine globalen AppleLanguages gefunden, benutze bestehende Prozess-Einstellung.")
        }

    
        // Dock-Sichtbarkeit beim Start anhand gespeicherter Einstellung setzen
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        let app = NSApplication.shared
        app.setActivationPolicy(showInDock ? .regular : .accessory)

        // ViewModel ERST JETZT erzeugen, damit alle NSLocalizedString()
        // die gerade synchronisierte Sprache sehen.
        _viewModel = StateObject(wrappedValue: IPv6PrefixViewModel())
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 0) {
                // Statuszeile
                Text(viewModel.statusText)
                    .font(.headline)
                    .foregroundColor(color(for: viewModel.statusKind))
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // WLAN – IPv6 + IPv4
                if let wlan = viewModel.wlanAddress {
                    Text(String(format: NSLocalizedString("WLAN (en1): %@", comment: "IPv6-Adresse für WLAN"), wlan))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.cyan)
                } else {
                    Text(NSLocalizedString("WLAN (en1): – keine globale IPv6-Adresse –", comment: "Kein globales IPv6 auf WLAN"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                if let wlan4 = viewModel.wlanIPv4Address {
                    Text(String(format: NSLocalizedString("IPv4: %@", comment: "IPv4-Adresse"), wlan4))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.8))
                } else {
                    Text(NSLocalizedString("IPv4: –", comment: "Keine IPv4-Adresse"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 4)

                // Ethernet – IPv6 + IPv4
                if let eth = viewModel.ethernetAddress {
                    Text(String(format: NSLocalizedString("Ethernet (en0): %@", comment: "IPv6-Adresse für Ethernet"), eth))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(color(for: viewModel.statusKind))
                } else {
                    Text(NSLocalizedString("Ethernet (en0): – keine globale IPv6-Adresse –", comment: "Kein globales IPv6 auf Ethernet"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                if let eth4 = viewModel.ethernetIPv4Address {
                    Text(String(format: NSLocalizedString("IPv4: %@", comment: "IPv4-Adresse"), eth4))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(color(for: viewModel.statusKind))
                } else {
                    Text(NSLocalizedString("IPv4: –", comment: "Keine IPv4-Adresse"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                if let lastCheck = viewModel.lastCheckDate {
                    Text(String(format: NSLocalizedString("Letzte Prüfung: %@", comment: "Zeitpunkt der letzten Prüfung"), formattedDate(lastCheck)))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text(NSLocalizedString("Letzte Prüfung: noch keine", comment: "Noch keine Prüfung durchgeführt"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if let lastChange = viewModel.lastPrefixChangeDate {
                    Text(String(format: NSLocalizedString("Letzter Fix: %@", comment: "Zeitpunkt des letzten Fixes"), formattedDate(lastChange)))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text(NSLocalizedString("Letzter Fix: noch keiner", comment: "Noch kein Fix durchgeführt"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Manuelle Prüfung
                Button(NSLocalizedString("Status prüfen", comment: "Manuelle Statusprüfung")) {
                    viewModel.checkStatus(autoFix: viewModel.autoFixEnabled)
                }
                .font(.system(.body))

                Divider()

                SettingsLink {
                    Text(NSLocalizedString("Einstellungen …", comment: "Einstellungen öffnen"))
                }

                Button(NSLocalizedString("Log anzeigen …", comment: "Log-Fenster öffnen")) {
                    openLogWindow()
                }
            
                Button(NSLocalizedString("Nach Updates suchen …", comment: "Manuelle Update-Prüfung")) {
                    viewModel.checkForUpdates()
                }

                Button(NSLocalizedString("Über „IPv6 Prefix Fixer“…", comment: "Über-Dialog öffnen")) {
                    NSApp.orderFrontStandardAboutPanel(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }

                Divider()

                Button(NSLocalizedString("App beenden", comment: "App beenden")) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(preferredColorScheme == .light ? Color.white : Color.clear)
            .applyOptionalColorScheme(preferredColorScheme)
        } label: {
            Image(systemName: viewModel.menuBarSymbolName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(color(for: viewModel.statusKind))
        }

        Settings {
            SettingsView(viewModel: viewModel)
                .applyOptionalColorScheme(preferredColorScheme)
                .background(preferredColorScheme == .light ? Color.white : Color.clear)
        }
    }

    // MARK: - Helper

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func color(for kind: IPv6StatusKind) -> Color {
        switch kind {
        case .ok:       return .green
        case .warning:  return .yellow
        case .error:    return .red
        case .inactive: return .gray
        }
    }


    // MARK: - Log-Fenster

    private func openLogWindow() {
        if let win = logWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: LogWindow(viewModel: viewModel))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = NSLocalizedString("IPv6PrefixHelper Log", comment: "Titel des Log-Fensters")
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.logWindow = window
    }
}

// Settings-Ansicht
struct SettingsView: View {
    @ObservedObject var viewModel: IPv6PrefixViewModel
    @AppStorage("showInDock") private var showInDock: Bool = true
    @State private var localAppearanceMode: String = "system"

    var body: some View {
        Form {
            // Reihe: Allgemein
            HStack(alignment: .top, spacing: 16) {
                Text(NSLocalizedString("Allgemein", comment: "Einstellungssektion Allgemein"))
                    .frame(width: 110, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        NSLocalizedString("Periodische Auto-Prüfung alle 5 Minuten aktivieren", comment: "Auto-Check einschalten"),
                        isOn: Binding(
                            get: { viewModel.periodicChecksEnabled },
                            set: { newValue in
                                viewModel.setPeriodicChecksEnabled(newValue)
                            }
                        )
                    )

                    Toggle(
                        NSLocalizedString("Automatisch IPv6 bei Fehler reparieren", comment: "Auto-Fix bei Fehler"),
                        isOn: $viewModel.autoFixEnabled
                    )
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Reihe: Darstellung
            HStack(alignment: .top, spacing: 16) {
                Text(NSLocalizedString("Darstellung", comment: "Einstellungssektion Darstellung"))
                    .frame(width: 110, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(NSLocalizedString("App im Dock anzeigen", comment: "App im Dock sichtbar"), isOn: $showInDock)
                        .onChange(of: showInDock) { _, newValue in
                            let app = NSApplication.shared
                            app.setActivationPolicy(newValue ? .regular : .accessory)
                        }

                    HStack(alignment: .center, spacing: 12) {
                        Text(NSLocalizedString("Anzeigemodus", comment: "Darstellungsmodus"))
                            .frame(width: 110, alignment: .leading)

                        Picker("", selection: $localAppearanceMode) {
                            Text(NSLocalizedString("System", comment: "Systemdarstellung"))
                                .tag("system")
                            Text(NSLocalizedString("Hell", comment: "Helles Design"))
                                .tag("light")
                            Text(NSLocalizedString("Dunkel", comment: "Dunkles Design"))
                                .tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Reihe: Debug
            HStack(alignment: .top, spacing: 16) {
                Text(NSLocalizedString("Debug", comment: "Einstellungssektion Debug"))
                    .frame(width: 110, alignment: .leading)

                Toggle(
                    NSLocalizedString("Debug-Logging (Konsole)", comment: "Debug-Logging aktivieren"),
                    isOn: $viewModel.debugLoggingEnabled
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(
            width: 500,
            height: 260
        )
        .onAppear {
            viewModel.startTimerIfNeeded()
            if let window = NSApp.keyWindow {
                window.level = .floating
            }
            // Appearance-Mode initial aus dem ViewModel übernehmen
            localAppearanceMode = viewModel.appearanceMode
        }
        .onChange(of: localAppearanceMode) { _, newValue in
            // Änderung asynchron an das ViewModel weiterreichen,
            // um "Publishing changes from within view updates" zu vermeiden
            DispatchQueue.main.async {
                viewModel.appearanceMode = newValue
            }
        }
    }
}

// MARK: - Optional Color Scheme Helper

private struct OptionalColorSchemeModifier: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        if let scheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}

private extension View {
    func applyOptionalColorScheme(_ scheme: ColorScheme?) -> some View {
        self.modifier(OptionalColorSchemeModifier(scheme: scheme))
    }
}
