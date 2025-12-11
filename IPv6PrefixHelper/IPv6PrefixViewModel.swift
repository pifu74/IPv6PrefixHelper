import Foundation
import Combine
import Network
import AppKit

/// Art des Status – beeinflusst Icon und Farben.
enum IPv6StatusKind {
    case ok
    case warning
    case error
    case inactive
}

/// Ein einzelner Log-Eintrag für das Log-Fenster.
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let text: String
}

/// ViewModel für die Menüleisten-App.
final class IPv6PrefixViewModel: ObservableObject {

    // MARK: - Published Properties (UI-Bindings)

    @Published var statusText: String = NSLocalizedString("status.initial", comment: "Status: Noch keine Prüfung durchgeführt.")
    @Published var statusKind: IPv6StatusKind = .inactive

    @Published var wlanAddress: String?
    @Published var ethernetAddress: String?

    // IPv4-Adressen
    @Published var wlanIPv4Address: String?
    @Published var ethernetIPv4Address: String?

    // ULA-Adressen (interne IPv6)
    @Published var wlanULAAddress: String?
    @Published var ethernetULAAddress: String?

    // Zuletzt beobachtetes globales Präfix (für Verlauf / Logging)
    @Published var lastObservedPrefix: String?

    @Published var lastCheckDate: Date?
    @Published var lastPrefixChangeDate: Date?

    // Settings
    @Published var autoCheckIntervalMinutes: Int = 5
    @Published var periodicChecksEnabled: Bool = true
    @Published var autoFixEnabled: Bool = true
    @Published var debugLoggingEnabled: Bool = false

    // Darstellung (für SettingsView)
    @Published var appearanceMode: String = "system"

    // MARK: - Log Buffer

    @Published var logEntries: [LogEntry] = []
    let maxLogEntries = 500

    // Keys für persistente Speicherung der letzten Zeiten
    private static let lastCheckDefaultsKey = "IPv6PrefixHelper.lastCheckDate"
    private static let lastFixDefaultsKey = "IPv6PrefixHelper.lastPrefixChangeDate"
    private static let lastObservedPrefixDefaultsKey = "IPv6PrefixHelper.lastObservedPrefix"
    private static let periodicChecksEnabledKey = "IPv6PrefixHelper.periodicChecksEnabled"

    // Wartezeit nach App-Start, bevor die erste Prüfung läuft
    private let initialDelaySeconds: TimeInterval = 10

    // MARK: - Timer

    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "IPv6PrefixHelper.PathMonitor")

    // Auto-Fix-Steuerung (Schutz vor Endlosschleifen)
    private var isAutoFixInProgress: Bool = false
    private var lastAutoFixDate: Date?
    private let autoFixCooldownSeconds: TimeInterval = 60

    // Generation-Counter, um veraltete Status-Updates nach parallelen Prüfungen zu ignorieren
    private var statusCheckGeneration: Int = 0
    private let statusGenerationQueue = DispatchQueue(label: "IPv6PrefixHelper.StatusGeneration")

    // Gemerkte letzte funktionierende IPv6-Default-Route
    private var lastKnownIPv6Router: String?
    private var lastKnownIPv6Interface: String?

    // MARK: - Initializer

    init() {
        // Vorhandene Werte aus UserDefaults laden (falls vorhanden)
        if let savedLastCheck = UserDefaults.standard.object(forKey: Self.lastCheckDefaultsKey) as? Date {
            self.lastCheckDate = savedLastCheck
        }
        if let savedLastFix = UserDefaults.standard.object(forKey: Self.lastFixDefaultsKey) as? Date {
            self.lastPrefixChangeDate = savedLastFix
        }

        // zuletzt beobachtetes Präfix laden (falls vorhanden)
        if let savedPrefix = UserDefaults.standard.string(forKey: Self.lastObservedPrefixDefaultsKey) {
            self.lastObservedPrefix = savedPrefix
        }

        // gespeicherten Status für periodische Prüfungen laden (falls vorhanden)
        if let savedPeriodic = UserDefaults.standard.object(forKey: Self.periodicChecksEnabledKey) as? Bool {
            self.periodicChecksEnabled = savedPeriodic
        }

        // Ereignis-basierter Trigger über NWPathMonitor
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            if self.isAutoFixInProgress {
                self.log(NSLocalizedString("log.netstatus.skipDuringAutoFix",
                                           comment: "Network status changed during auto-fix; automatic check is skipped."))
                return
            }

            let statusDescription: String
            switch path.status {
            case .satisfied:
                statusDescription = NSLocalizedString("log.netstatus.ok", comment: "Network status: connection available")
            case .unsatisfied:
                statusDescription = NSLocalizedString("log.netstatus.nok", comment: "Network status: no connection")
            case .requiresConnection:
                statusDescription = NSLocalizedString("log.netstatus.requiresConnection", comment: "Network status: requires connection")
            @unknown default:
                statusDescription = String(format: NSLocalizedString("log.netstatus.unknown", comment: "Network status: unknown status"), String(describing: path.status))
            }

            self.log(String(format: NSLocalizedString("log.netstatus.changed", comment: "Network status changed"), statusDescription))

            // Nur bei funktionierender Verbindung automatisch prüfen
            if path.status == .satisfied {
                self.checkStatus(autoFix: self.autoFixEnabled)
            } else {
                self.log(NSLocalizedString("log.netstatus.noAutoCheck", comment: "Network status changed: no automatic check when status not satisfied"))
            }
        }

        monitor.start(queue: pathMonitorQueue)

        log(String(format: NSLocalizedString("log.init.firstCheck", comment: "ViewModel init – start first check after N seconds (with auto-fix)"), initialDelaySeconds))

        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelaySeconds) {
            // Erster Check nach Start: prüfen und bei Bedarf automatisch fixen
            self.checkStatus(autoFix: true)
            self.startTimerIfNeeded()
        }
    }

    // Menüleisten-Symbolname abhängig vom Status
    var menuBarSymbolName: String {
        switch statusKind {
        case .ok:       return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .error:    return "xmark.octagon.fill"
        case .inactive: return "questionmark.diamond.fill"
        }
    }

    /// Timer neu setzen (z. B. nach Statusänderung).
    func startTimerIfNeeded() {
        timer?.invalidate()

        // Periodische Prüfungen können über die Einstellungen deaktiviert werden
        guard periodicChecksEnabled else { return }

        let interval: TimeInterval = 5 * 60  // festes 5-Minuten-Intervall

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.handleAutoCheckTimerFired()
        }
    }

    /// Aktiviert oder deaktiviert periodische Prüfungen und speichert die Einstellung.
    func setPeriodicChecksEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.periodicChecksEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Self.periodicChecksEnabledKey)
            self.startTimerIfNeeded()
        }
    }

    /// Wird vom Auto-Timer aufgerufen: setzt die Baseline für den Countdown und startet die Prüfung.
    private func handleAutoCheckTimerFired() {
        let now = Date()
        lastCheckDate = now
        UserDefaults.standard.set(now, forKey: Self.lastCheckDefaultsKey)

        checkStatus(autoFix: true)
    }


    // MARK: - Update-Check (GitHub)

    /// Führt eine manuelle Update-Prüfung gegen das GitHub-Release-API durch.
    /// Ergebnis wird ausschließlich im Log festgehalten; bei neuer Version wird
    /// die Release-Seite im Standardbrowser geöffnet.
    func checkForUpdates() {
        let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        log(String(format: NSLocalizedString("log.updateCheck.start",
                                             comment: "Manual update check started for current version"),
                   currentVersion))

        guard let url = URL(string: "https://api.github.com/repos/pifu74/IPv6PrefixHelper/releases/latest") else {
            log(NSLocalizedString("log.updateCheck.invalidUrl",
                                  comment: "Update check failed: invalid GitHub URL"))
            return
        }

        let request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            func showUpdateAlert(titleKey: String, messageKey: String, _ args: CVarArg...) {
                let title = NSLocalizedString(titleKey,
                                              comment: "Title for update check alert")
                let format = NSLocalizedString(messageKey,
                                               comment: "Message for update check alert")
                let message = String(format: format, arguments: args)
                let okTitle = NSLocalizedString("updateCheck.alert.ok",
                                                comment: "OK button title for update check alerts")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = title
                    alert.informativeText = message
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: okTitle)
                    alert.runModal()
                }
            }
            if let error = error {
                self.log(String(format: NSLocalizedString("log.updateCheck.error",
                                                          comment: "Update check failed with error"),
                                error.localizedDescription))
                showUpdateAlert(titleKey: "updateCheck.alert.title.error",
                                messageKey: "updateCheck.alert.message.error",
                                error.localizedDescription)
                return
            }

            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                self.log(NSLocalizedString("log.updateCheck.invalidResponse",
                                           comment: "Update check failed: invalid response data"))
                showUpdateAlert(titleKey: "updateCheck.alert.title.error",
                                messageKey: "updateCheck.alert.message.invalidResponse")
                return
            }

            let tag = (json["tag_name"] as? String) ?? ""
            let htmlUrlString = (json["html_url"] as? String) ?? ""

            guard !tag.isEmpty else {
                self.log(NSLocalizedString("log.updateCheck.noTag",
                                           comment: "Update check failed: tag_name missing in GitHub response"))
                showUpdateAlert(titleKey: "updateCheck.alert.title.error",
                                messageKey: "updateCheck.alert.message.noTag")
                return
            }

            // Führendes "v" im Tag entfernen (z. B. "v1.0.2" → "1.0.2")
            let latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            self.log(String(format: NSLocalizedString("log.updateCheck.latestVersion",
                                                      comment: "Latest GitHub version string"),
                            latestVersion))

            // Wenn Versionen exakt übereinstimmen → alles aktuell
            if latestVersion == currentVersion {
                self.log(String(format: NSLocalizedString("log.updateCheck.noUpdate",
                                                          comment: "Update check: app is up to date"),
                                currentVersion))
                showUpdateAlert(titleKey: "updateCheck.alert.title.upToDate",
                                messageKey: "updateCheck.alert.message.upToDate",
                                currentVersion)
                return
            }

            // Semantischen Versionsvergleich nutzen, um "neuer" zu erkennen
            if self.isVersion(latestVersion, newerThan: currentVersion) {
                self.log(String(format: NSLocalizedString("log.updateCheck.updateAvailable",
                                                          comment: "Update available: current vs latest"),
                                currentVersion,
                                latestVersion))
                showUpdateAlert(titleKey: "updateCheck.alert.title.updateAvailable",
                                messageKey: "updateCheck.alert.message.updateAvailable",
                                currentVersion,
                                latestVersion)
                if let htmlUrl = URL(string: htmlUrlString) {
                    self.log(NSLocalizedString("log.updateCheck.openReleases",
                                               comment: "Opening GitHub releases page in browser"))
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(htmlUrl)
                    }
                }
            } else {
                // Lokale Version ist neuer (z. B. Dev-Build)
                self.log(String(format: NSLocalizedString("log.updateCheck.localNewer",
                                                          comment: "Local version is newer than GitHub latest"),
                                currentVersion,
                                latestVersion))
                showUpdateAlert(titleKey: "updateCheck.alert.title.localNewer",
                                messageKey: "updateCheck.alert.message.localNewer",
                                currentVersion,
                                latestVersion)
            }
        }

        task.resume()
    }

    /// Vergleicht zwei Versionsstrings im Format "X.Y.Z" und ermittelt,
    /// ob `v1` neuer ist als `v2`.
    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let a = v1.split(separator: ".").map { Int($0) ?? 0 }
        let b = v2.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)

        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0

            if x > y { return true }
            if x < y { return false }
        }

        // Gleich oder nicht eindeutig neuer
        return false
    }

    // MARK: - Hauptlogik

    func checkStatus(autoFix: Bool) {
        // Jede Prüfung erhält eine eigene Generation-ID, damit bei parallelen Checks
        // nur das Ergebnis der zuletzt gestarteten Prüfung den UI-Status überschreibt.
        let generation: Int = statusGenerationQueue.sync {
            self.statusCheckGeneration &+= 1
            return self.statusCheckGeneration
        }
        log(String(format: NSLocalizedString("log.checkStatus.start", comment: "Start status check"), autoFix ? "true" : "false"))

        DispatchQueue.global(qos: .background).async {
            // IPv6-Adressen
            let wlan = self.globalIPv6Address(forInterface: "en1")
            let eth  = self.globalIPv6Address(forInterface: "en0")

            // IPv4-Adressen
            let wlanV4 = self.ipv4Address(forInterface: "en1")
            let ethV4  = self.ipv4Address(forInterface: "en0")

            let wlanPrefix = self.prefix(fromIPv6: wlan)
            let ethPrefix  = self.prefix(fromIPv6: eth)

            // ULA-Adressen separat ermitteln (für interne Erreichbarkeit)
            let wlanULA = self.ulaIPv6Address(forInterface: "en1")
            let ethULA  = self.ulaIPv6Address(forInterface: "en0")

            let anyGlobal = (wlanPrefix != nil || ethPrefix != nil)
            let hasULA    = (wlanULA != nil || ethULA != nil)

            // Aktuelle Default-Route parsen (falls vorhanden)
            let defaultRoute = self.currentIPv6DefaultRoute()
            let hasDefaultRoute = (defaultRoute != nil)

            self.log(String(format: NSLocalizedString("log.found.ipv6", comment: "Found IPv6 addresses"), wlan ?? "nil", eth ?? "nil"))
            self.log(String(format: NSLocalizedString("log.found.ula", comment: "Found ULA addresses"), wlanULA ?? "nil", ethULA ?? "nil"))
            self.log(String(format: NSLocalizedString("log.found.ipv4", comment: "Found IPv4 addresses"), wlanV4 ?? "nil", ethV4 ?? "nil"))
            self.log(String(format: NSLocalizedString("log.prefixes", comment: "Observed prefixes"), wlanPrefix ?? "nil", ethPrefix ?? "nil"))

            // IPv6-Konnektivität testen, wenn überhaupt globale Adressen existieren
            var hasIPv6Connectivity = false
            if anyGlobal {
                hasIPv6Connectivity = self.testIPv6Connectivity(timeout: 5)
                self.log(String(format: NSLocalizedString("log.ipv6.connectivity", comment: "IPv6 connectivity result"), hasIPv6Connectivity ? "true" : "false"))
            }

            DispatchQueue.main.async {
                // Wenn inzwischen eine neuere Prüfung gestartet wurde, dieses Ergebnis ignorieren.
                guard generation == self.statusCheckGeneration else {
                    return
                }
                // Auto-Fix-Cooldown berechnen, um Endlosschleifen zu vermeiden
                let nowForAutofix = Date()
                let canRunAutoFixAgain: Bool
                if let lastFix = self.lastAutoFixDate,
                   nowForAutofix.timeIntervalSince(lastFix) < self.autoFixCooldownSeconds {
                    canRunAutoFixAgain = false
                } else {
                    canRunAutoFixAgain = true
                }

                self.wlanAddress = wlan
                self.ethernetAddress = eth
                self.wlanIPv4Address = wlanV4
                self.ethernetIPv4Address = ethV4
                self.wlanULAAddress = wlanULA
                self.ethernetULAAddress = ethULA

                // Default-Route-Information (falls vorhanden) merken
                if let route = defaultRoute {
                    self.log(String(format: NSLocalizedString("log.defaultRoute.current", comment: "Current IPv6 default route"), route.gateway, route.iface))
                    self.lastKnownIPv6Router = route.gateway
                    self.lastKnownIPv6Interface = route.iface
                }

                // Präfix-Verlauf / State-Management (Ethernet bevorzugt, sonst WLAN)
                let canonicalPrefix = ethPrefix ?? wlanPrefix
                let oldPrefix = self.lastObservedPrefix

                if let newPrefix = canonicalPrefix {
                    if let old = oldPrefix, old != newPrefix {
                        self.log(String(format: NSLocalizedString("log.prefix.changed", comment: "IPv6 prefix changed"), old, newPrefix))
                    } else if oldPrefix == nil {
                        self.log(String(format: NSLocalizedString("log.prefix.firstObserved", comment: "First observed IPv6 prefix"), newPrefix))
                    }

                    self.lastObservedPrefix = newPrefix
                    UserDefaults.standard.set(newPrefix, forKey: Self.lastObservedPrefixDefaultsKey)
                } else {
                    if oldPrefix != nil {
                        self.log(NSLocalizedString("log.prefix.lost", comment: "Global IPv6 prefix lost"))
                    }
                    self.lastObservedPrefix = nil
                    UserDefaults.standard.removeObject(forKey: Self.lastObservedPrefixDefaultsKey)
                }

                let now = Date()
                self.lastCheckDate = now
                UserDefaults.standard.set(now, forKey: Self.lastCheckDefaultsKey)

                // Wenn keine globale IPv6-Adresse mehr vorhanden ist (Präfix weg)
                guard anyGlobal else {
                    if hasULA {
                        // Nur ULA-Adressen → interne Dienste möglich, Internet via IPv6 vermutlich defekt
                        self.statusKind = .error
                        self.statusText = NSLocalizedString("status.ulaOnly", comment: "Status: Nur ULA-Adressen vorhanden – vermute verlorenes Präfix, IPv6-Internet nicht erreichbar.")

                        if autoFix && self.autoFixEnabled {
                            if canRunAutoFixAgain {
                                self.lastAutoFixDate = nowForAutofix
                                self.log(NSLocalizedString("log.autoFix.ulaOnly", comment: "Only ULA addresses – assume lost prefix, run auto-fix"))
                                self.repairIPv6Interfaces()
                            } else {
                                self.log(NSLocalizedString("log.autoFix.skipped.ulaOnlyRecently",
                                                           comment: "Auto-fix skipped for ULA-only case because it was run recently."))
                            }
                        }
                    } else {
                        // Weder globale IPv6 noch ULA → Konfiguration fehlt komplett oder Interface down
                        self.statusKind = .warning
                        self.statusText = NSLocalizedString("status.noGlobalIPv6", comment: "Status: keine globale IPv6-Adresse konfiguriert")
                    }
                    return
                }

                // Zusätzlicher Health-Check: Fehlt die IPv6-Default-Route trotz globaler Adressen?
                if anyGlobal && hasDefaultRoute == false {
                    self.statusKind = .error
                    self.statusText = NSLocalizedString("status.noDefaultRoute", comment: "Status: Fehler – IPv6-Default-Route fehlt (RA-Stille vermutet).")

                    if autoFix && self.autoFixEnabled {
                        if canRunAutoFixAgain {
                            self.lastAutoFixDate = nowForAutofix
                            self.log(NSLocalizedString("log.error.noDefaultRoute.autofix", comment: "Error: no IPv6 default route, running auto-fix"))
                            self.repairIPv6Interfaces()
                        } else {
                            self.log(NSLocalizedString("log.autoFix.skipped.noDefaultRouteRecently",
                                                       comment: "Auto-fix skipped for missing default route because it was run recently."))
                        }
                    } else {
                        self.log(NSLocalizedString("log.error.noDefaultRoute.noAutofix", comment: "Error: no IPv6 default route, auto-fix disabled"))
                    }

                    return
                }

                // Prüfen, ob Ethernet die primäre, funktionierende IPv6-Verbindung ist.
                // Wenn das der Fall ist, kann ein Präfix-Mismatch zum WLAN ignoriert werden.
                let ethernetIsPrimary =
                    (ethPrefix != nil) &&
                    hasIPv6Connectivity &&
                    (defaultRoute?.iface == "en0")

                // Fall 1: Präfix-Mismatch zwischen WLAN und Ethernet
                if let wp = wlanPrefix, let ep = ethPrefix, wp != ep {
                    if ethernetIsPrimary {
                        // Ethernet ist primär und IPv6 funktioniert – WLAN-Präfix wird ignoriert.
                        // Kein Statuswechsel, kein Auto-Fix; es geht direkt mit den weiteren Checks weiter.
                    } else {
                        self.statusKind = .warning
                        self.statusText = NSLocalizedString("status.prefixMismatch", comment: "Status: Präfixe von WLAN und Ethernet unterscheiden sich")
                        if autoFix && self.autoFixEnabled {
                            if canRunAutoFixAgain {
                                self.lastAutoFixDate = nowForAutofix
                                self.log(NSLocalizedString("log.autoFix.prefixMismatch", comment: "Prefix mismatch – run auto-fix"))
                                self.repairIPv6Interfaces()
                            } else {
                                self.log("Auto-Fix wird übersprungen (Präfix-Mismatch) – vor kurzem bereits ausgeführt.")
                            }
                        }
                        return
                    }
                }

                // Fall 2: Präfixe gleich, aber IPv6 tot
                if hasIPv6Connectivity == false {
                    self.statusKind = .error
                    self.statusText = NSLocalizedString("status.ipv6Dead", comment: "Status: Präfix vermutlich veraltet, IPv6 nicht erreichbar")
                    if autoFix && self.autoFixEnabled {
                        if canRunAutoFixAgain {
                            self.lastAutoFixDate = nowForAutofix
                            self.log(NSLocalizedString("log.autoFix.ipv6Dead", comment: "IPv6 dead despite matching prefixes – run auto-fix"))
                            self.repairIPv6Interfaces()
                        } else {
                            self.log(NSLocalizedString("log.autoFix.skipped.ipv6DeadRecently",
                                                       comment: "Auto-fix skipped for dead IPv6 because it was run recently."))
                        }
                    }
                    return
                }

                // Fall 3: alles gut
                self.statusKind = .ok
                self.statusText = NSLocalizedString("status.ok", comment: "Status: Alles in Ordnung – Präfixe stimmen überein")
            }
        }
    }

    // MARK: - ULA-Ermittlung (interne IPv6-Adressen)

    private func ulaIPv6Address(forInterface name: String) -> String? {
        let output = runShell("/sbin/ifconfig", [name])
        guard !output.isEmpty else { return nil }

        let lines = output.split(separator: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet6 ") else { continue }

            let parts = trimmed.split(separator: " ")
            guard parts.count >= 2 else { continue }

            let addr = String(parts[1])

            // Link-local rausfiltern, nur ULA (fd/fc) behalten
            if addr.hasPrefix("fe80:") { continue }
            if addr.hasPrefix("fd") || addr.hasPrefix("fc") {
                return addr
            }
        }

        return nil
    }

    // MARK: - IPv6-Ermittlung

    private func globalIPv6Address(forInterface name: String) -> String? {
        let output = runShell("/sbin/ifconfig", [name])
        guard !output.isEmpty else { return nil }

        let lines = output.split(separator: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet6 ") else { continue }

            let parts = trimmed.split(separator: " ")
            guard parts.count >= 2 else { continue }

            let addr = String(parts[1])

            // Link-local & ULA filtern
            if addr.hasPrefix("fe80:") { continue }
            if addr.hasPrefix("fd") || addr.hasPrefix("fc") { continue }

            return addr
        }

        return nil
    }

    // MARK: - IPv4-Ermittlung

    private func ipv4Address(forInterface name: String) -> String? {
        let output = runShell("/sbin/ifconfig", [name])
        guard !output.isEmpty else { return nil }

        let lines = output.split(separator: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else { continue }

            // Beispiel:
            // inet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255
            let parts = trimmed.split(separator: " ")
            guard parts.count >= 2 else { continue }

            let addr = String(parts[1])

            // Loopback & APIPA rausfiltern
            if addr.hasPrefix("127.") { continue }
            if addr.hasPrefix("169.254.") { continue }

            return addr
        }

        return nil
    }

    /// Extrahiert einen "Präfixstring" aus einer IPv6-Adresse (erste 4 Hextets).
    private func prefix(fromIPv6 address: String?) -> String? {
        guard let address = address else { return nil }
        let cleaned = address.split(separator: "%").first ?? Substring(address) // %en0 entfernen
        let hextets = cleaned.split(separator: ":")
        guard hextets.count >= 4 else { return nil }
        return hextets[0...3].joined(separator: ":")
    }

    // MARK: - Default-Route-Check (IPv6)

    /// Liefert die aktuelle IPv6-Default-Route (Gateway + Interface), falls vorhanden.
    private func currentIPv6DefaultRoute() -> (gateway: String, iface: String)? {
        let output = runShell("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
        guard !output.isEmpty else { return nil }

        let lines = output.split(separator: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Typische Default-Route-Zeile: "default fe80::1%en0 ..."
            guard trimmed.hasPrefix("default ") else { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }

            let rawGateway = String(parts[1])
            // Interface-Scope (z. B. "%en1") entfernen, damit wir einen universell nutzbaren Router speichern
            let gateway = rawGateway.split(separator: "%").first.map(String.init) ?? rawGateway
            let iface   = String(parts.last!)
            return (gateway: gateway, iface: iface)
        }

        return nil
    }

    private func hasIPv6DefaultRoute() -> Bool {
        return currentIPv6DefaultRoute() != nil
    }

    // MARK: - IPv6-Konnektivitätstest

    private func testIPv6Connectivity(timeout: TimeInterval) -> Bool {
        // Ziel-Liste mit Namen für das Log
        let targets: [(name: String, address: String)] = [
            ("Cloudflare", "2606:4700:4700::1111"),
            ("Google",     "2001:4860:4860::8888")
        ]

        for target in targets {
            let urlString = "https://[\(target.address)]/"
            guard let url = URL(string: urlString) else {
                self.log(String(format: NSLocalizedString("log.ipv6test.invalidUrl", comment: "IPv6 test: invalid URL"), target.name, urlString))
                return false
            }

            self.log(String(format: NSLocalizedString("log.ipv6test.start", comment: "Start IPv6 target test"), target.name, target.address))

            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            let session = URLSession(configuration: config)

            var result: Bool?
            let semaphore = DispatchSemaphore(value: 0)

            let task = session.dataTask(with: url) { _, response, error in
                var logDetail: String

                if let http = response as? HTTPURLResponse {
                    if (200..<400).contains(http.statusCode), error == nil {
                        result = true
                        logDetail = "OK (HTTP \(http.statusCode))"
                    } else {
                        result = false
                        if let error = error {
                            logDetail = "ERROR – \(error.localizedDescription) (HTTP \(http.statusCode))"
                        } else {
                            logDetail = "ERROR – HTTP \(http.statusCode)"
                        }
                    }
                } else if let error = error {
                    result = false
                    logDetail = "ERROR – \(error.localizedDescription)"
                } else {
                    result = false
                    logDetail = "ERROR – no HTTP response"
                }

                self.log(String(format: NSLocalizedString("log.ipv6test.result", comment: "IPv6 test result"), target.name, logDetail))
                semaphore.signal()
            }

            task.resume()
            let waitResult = semaphore.wait(timeout: .now() + timeout)

            if waitResult == .timedOut {
                task.cancel()
                self.log(String(format: NSLocalizedString("log.ipv6test.timeout", comment: "IPv6 test timeout"), target.name, timeout))

                // Zusätzlicher Health-Check nur im Fehlerfall
                self.log(NSLocalizedString("log.healthCheck.timeout.start", comment: "Health check (timeout): ping6 dns.google"))
                let pingOK = self.pingIPv6Host("dns.google")
                self.log(String(format: NSLocalizedString("log.healthCheck.timeout.result", comment: "Health check (timeout) result"), pingOK ? "OK" : "FEHLER"))

                return false
            }

            // Wenn dieses Ziel nicht erfolgreich war → insgesamt kein IPv6-OK
            if result != true {
                self.log(String(format: NSLocalizedString("log.ipv6test.httpFailed", comment: "IPv6 HTTP check failed"), target.name))

                // Zusätzlicher Health-Check nur im Fehlerfall
                self.log(NSLocalizedString("log.healthCheck.httpError.start", comment: "Health check (HTTP error): ping6 dns.google"))
                let pingOK = self.pingIPv6Host("dns.google")
                self.log(String(format: NSLocalizedString("log.healthCheck.httpError.result", comment: "Health check (HTTP error) result"), pingOK ? "OK" : "FEHLER"))

                return false
            }
        }

        self.log(NSLocalizedString("log.ipv6test.allOk", comment: "All IPv6 targets reachable"))
        return true
    }

    // MARK: - Reparatur-Logik (networksetup)

    private func repairIPv6Interfaces() {
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.main.async {
                self.isAutoFixInProgress = true
            }
            // 1. Erstmal IPv6 auf "Ethernet" einmal komplett neu aushandeln lassen
            self.log(NSLocalizedString("log.autoFix.resetEthernetAutomatic",
                                       comment: "Auto-fix: reset IPv6 on 'Ethernet' from OFF to AUTOMATIC."))
            self.toggleIPv6(onService: "Ethernet")

            // Kurze Pause, damit RA/DHCPv6 greifen kann
            Thread.sleep(forTimeInterval: 3)

            // 2. Frisch zugewiesene Adresse + Default-Route auslesen
            let freshEthIPv6 = self.globalIPv6Address(forInterface: "en0")
            let defaultRoute = self.currentIPv6DefaultRoute()

            self.log(String(format: NSLocalizedString("log.autoFix.afterResetSummary",
                                                      comment: "Auto-fix: after reset – summary of Ethernet IPv6 and default route."),
                            freshEthIPv6 ?? "nil",
                            defaultRoute?.gateway ?? "nil",
                            defaultRoute?.iface ?? "nil"))

            // 3. Wenn entweder Adresse oder Router fehlen: im Automatik-Modus bleiben
            guard
                let ipv6Address = freshEthIPv6,
                let route = defaultRoute,
                route.iface == "en0" // wir wollen wirklich die Route für Ethernet benutzen
            else {
                self.log(NSLocalizedString("log.autoFix.noValidComboStayAutomatic",
                                           comment: "Auto-fix: no valid IPv6 address/default route combination found; keep automatic mode."))
                DispatchQueue.main.async {
                    let now = Date()
                    self.lastPrefixChangeDate = now
                    UserDefaults.standard.set(now, forKey: Self.lastFixDefaultsKey)
                    self.statusKind = .warning
                    self.statusText = NSLocalizedString("status.autoFix.renewedAutomatic",
                                                        comment: "Status: IPv6 configuration renewed in automatic mode; will re-check.")
                    self.isAutoFixInProgress = false
                }

                // Auch in diesem Fall Status nochmal prüfen, aber ohne weiteren Auto-Fix
                self.checkStatus(autoFix: false)
                return
            }

            // 4. Wenn wir hier sind, haben wir eine gültige Adresse + Router → auf MANUELL umstellen
            let prefixLength = "64" // bei Heimanschlüssen praktisch immer /64
            self.log(String(format: NSLocalizedString("log.autoFix.setManualFromAuto",
                                                      comment: "Auto-fix: set IPv6 for 'Ethernet' to MANUAL with address and router obtained from automatic configuration."),
                            ipv6Address,
                            prefixLength,
                            route.gateway))

            _ = self.runShell("/usr/sbin/networksetup", [
                "-setv6manual", "Ethernet", ipv6Address, prefixLength, route.gateway
            ])

            // Kleine Pause, dann erneute Prüfung ohne Auto-Fix
            Thread.sleep(forTimeInterval: 2)

            DispatchQueue.main.async {
                let now = Date()
                self.lastPrefixChangeDate = now
                UserDefaults.standard.set(now, forKey: Self.lastFixDefaultsKey)
                self.statusKind = .warning
                self.statusText = NSLocalizedString("status.autoFix.manualFromAuto",
                                                    comment: "Status: IPv6 was set to manual on 'Ethernet' based on previous automatic configuration; will re-check.")
                self.isAutoFixInProgress = false
            }

            self.checkStatus(autoFix: false)
        }
    }

    private func toggleIPv6(onService service: String) {
        log(String(format: NSLocalizedString("log.toggleIPv6.reset", comment: "Reset IPv6 mode for service"), service))
        _ = runShell("/usr/sbin/networksetup", ["-setv6off", service])
        Thread.sleep(forTimeInterval: 1)
        _ = runShell("/usr/sbin/networksetup", ["-setv6automatic", service])
        log(String(format: NSLocalizedString("log.toggleIPv6.nowAutomatic", comment: "IPv6 mode for service is now automatic"), service))
    }

    // MARK: - Shell Helper

    @discardableResult
    private func runShell(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            log(String(format: NSLocalizedString("log.shell.launchError", comment: "Error launching process"), launchPath, error.localizedDescription))
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Zusätzlicher Health-Check (ping6)

    private func pingIPv6Host(_ host: String, count: Int = 1, timeoutSeconds: Int = 1) -> Bool {
        let process = Process()
        process.launchPath = "/sbin/ping6"
        process.arguments = ["-c", "\(count)", "-W", "\(timeoutSeconds)", host]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            log(String(format: NSLocalizedString("log.ping.launchError", comment: "Error launching ping6"), error.localizedDescription))
            return false
        }

        process.waitUntilExit()
        let status = process.terminationStatus

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8), debugLoggingEnabled {
            // Optional: vollständige ping-Ausgabe in der Konsole für Debugging
            print("[ping6 output]", output)
        }

        return status == 0
    }

    deinit {
        timer?.invalidate()
        pathMonitor?.cancel()
    }

    // MARK: - Log-Steuerung (für das Fenster)

    func clearLog() {
        DispatchQueue.main.async {
            self.logEntries.removeAll()
        }
    }

    // MARK: - Logging

    /// Fügt einen Zeitstempel hinzu und schreibt die bereits lokalisierten Log-Nachrichten ins UI / die Konsole.
    /// Der übergebene String wird als fertiger, lokalisierter Text behandelt –
    /// Aufrufer sind verantwortlich dafür, `NSLocalizedString` (ggf. mit `String(format:)`) zu verwenden.
    private func log(_ message: String) {
        // Datum/Uhrzeit im deutschen Format DD.MM.YYYY, HH:MM:SS
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let ts = formatter.string(from: Date())

        let entryText = "[\(ts)] \(message)"

        if debugLoggingEnabled {
            print("[IPv6PrefixViewModel] \(entryText)")
        }

        DispatchQueue.main.async {
            self.logEntries.append(LogEntry(text: entryText))
            if self.logEntries.count > self.maxLogEntries {
                self.logEntries.removeFirst(self.logEntries.count - self.maxLogEntries)
            }
        }
    }
}
