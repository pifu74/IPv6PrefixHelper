# IPv6PrefixHelper

![Platform macOS](https://img.shields.io/badge/platform-macOS-1f6feb?logo=apple)
![Swift](https://img.shields.io/badge/swift-5.9-orange?logo=swift)
![Xcode](https://img.shields.io/badge/Xcode-16-blue)
![License: GPL v3](https://img.shields.io/badge/License-GPLv3-green.svg)
![Status: Stable](https://img.shields.io/badge/status-stable-success)

Ein leichter, vollständig lokal laufender macOS-Menüleistenhelfer zur automatischen Erkennung und Reparatur eines bekannten IPv6-Problems auf Systemen mit UniFi Cloud Gateway Ultra (oder ähnlichen Routern), bei denen Router Advertisements (RA) sporadisch ausfallen oder Präfixe verloren gehen.

Der IPv6PrefixHelper überwacht IPv6-Konnektivität über `NWPathMonitor`, analysiert globale IPv6-Adressen, Präfixe, ULA-Adressen und Default-Routen und kann – falls nötig – das Interface „Ethernet“ zuverlässig reparieren.

---

## ✨ Features

- Automatische Überwachung des IPv6-Status
- Erkennung von:
  - fehlenden RA-Paketen
  - verlorenen Präfixen
  - fehlender IPv6-Default-Route
  - Präfix-Mismatch zwischen WLAN und Ethernet
- Automatische Reparatur von IPv6 auf Ethernet:
  - Bezug einer neuen IPv6 via Auto-Modus
  - Wechsel zurück zu manuell mit gültiger Adresse
- Lokalisierung: **Deutsch** & **Englisch** vollständig unterstützt
- Debug-Fenster mit vollständigem Log
- Minimaler Ressourcenbedarf, komplett lokal, keine Cloud-Verbindungen

---

## 🔧 Installation

Aktuell gibt es **keine notarisierten Releases**.  
Du kannst die App auf zwei Arten erhalten:

### 1. Selbst kompilieren (empfohlen)
- Xcode 15 oder neuer
- Projekt klonen
- Build & Run

### 2. Vorgefertigte Binary (nicht notarisiert)
macOS verlangt beim ersten Start eine manuelle Bestätigung in den Systemeinstellungen unter  
**Sicherheit & Datenschutz → App erlauben**.

---

## 🧪 Kompatibilität

Getestet unter:

- macOS Sonoma (14.x)
- UniFi Cloud Gateway Ultra
- Weitere Router, die IPv6-RA-Probleme aufweisen könnten

---

## 📄 Lizenz

Dieses Projekt steht unter der **GNU GPLv3**.  
Das bedeutet u. a.:

- freie private & kommerzielle Nutzung des Quellcodes
- Änderungen dürfen veröffentlicht werden
- Weitergabe von Binaries erfordert Bereitstellung des (modifizierten) Quellcodes
- keine proprietären Forks erlaubt

👉 Die vollständige Lizenz findest du in der Datei `LICENSE`.

---

# English Version

# IPv6PrefixHelper

![Platform macOS](https://img.shields.io/badge/platform-macOS-1f6feb?logo=apple)
![Swift](https://img.shields.io/badge/swift-5.9-orange?logo=swift)
![Xcode](https://img.shields.io/badge/Xcode-15.1-blue?logo=xcode)
![License: GPL v3](https://img.shields.io/badge/License-GPLv3-green.svg)
![Status: Stable](https://img.shields.io/badge/status-stable-success)

A lightweight macOS menu-bar helper that detects and automatically repairs a common IPv6 issue seen on systems using UniFi Cloud Gateway Ultra (and similar routers) where Router Advertisements (RA) sometimes fail or IPv6 prefixes become stale.

The app continuously monitors IPv6 connectivity, analyses global addresses, prefixes, ULA, and default routes, and automatically repairs the “Ethernet” IPv6 configuration when needed.

---

## ✨ Features

- Automatic IPv6 monitoring
- Detection of:
  - missing RA packets
  - lost IPv6 prefixes
  - missing IPv6 default route
  - prefix mismatch between Wi-Fi and Ethernet
- Automatic repair mechanism:
  - temporarily switch to auto IPv6
  - capture valid address & router
  - switch back to manual mode with correct values
- Full localization support (English & German)
- Debug window with live log
- No external dependencies, no cloud calls

---

## 🔧 Installation

### 1. Build from source (recommended)
- Requires Xcode 15 or later
- Clone repo → Build → Run

### 2. Prebuilt binary (not notarized)
macOS requires manual approval before the app can run  
**System Settings → Privacy & Security → Allow Anyway**.

---

## 🧪 Compatibility

Tested on:

- macOS Sonoma (14.x)
- UniFi Cloud Gateway Ultra
- Other routers with RA issues

---

## 📄 License

Licensed under **GNU GPLv3**.

This requires:

- source availability when redistributing
- derivative works must also be GPLv3
- no closed-source forks allowed

See the `LICENSE` file for full terms.

---

If you appreciate this project, feel free to ⭐ star the repo on GitHub!
