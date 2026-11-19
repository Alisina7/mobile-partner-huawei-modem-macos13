import Foundation
import AppKit
import Combine

enum LinkState {
    case noModem
    case driverInactive
    case ready
    case connecting
    case connected
    case disconnecting
    case error

    var title: String {
        switch self {
        case .noModem: return "No modem"
        case .driverInactive: return "Driver inactive"
        case .ready: return "Ready"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting"
        case .error: return "Error"
        }
    }

    var isActive: Bool {
        self == .connecting || self == .connected || self == .disconnecting
    }
}

struct LogEntry: Identifiable {
    enum Level {
        case info
        case success
        case error
        case detail
    }

    let id = UUID()
    let date = Date()
    let text: String
    let level: Level
}

final class ModemModel: ObservableObject {
    @Published var link: LinkState = .noModem
    @Published var telemetry = Telemetry()
    @Published var pcuiPort: String?
    @Published var modemPort: String?
    @Published var log: [LogEntry] = []
    @Published var apn: String {
        didSet { defaults.set(apn, forKey: "apn") }
    }
    @Published var phone: String {
        didSet { defaults.set(phone, forKey: "phone") }
    }
    @Published var username: String {
        didSet { defaults.set(username, forKey: "username") }
    }
    @Published var password = ""
    @Published var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: "autoConnect") }
    }
    @Published var busy = false
    @Published var helperOnline = false
    @Published var driverLoaded = false
    @Published var usbDevices: [HuaweiUSBDevice] = []
    @Published var lastError: String?
    @Published var logExpanded = true
    @Published var advancedExpanded = false
    @Published var connectedSince: Date?
    @Published var uptimeText = "—"
    @Published var bytesIn: Int64 = 0
    @Published var bytesOut: Int64 = 0
    @Published var ipAddress: String?

    private let defaults = UserDefaults.standard
    private let engine = ATEngine()
    private let helper = HelperClient()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var tickCount = 0
    private var started = false
    private var statusPollInFlight = false
    private var hardwarePollInFlight = false
    private var helperPingInFlight = false
    private var connectStartedAt: Date?
    private var didAutoConnect = false
    private var lastPortSignature = ""
    private var lastLoggedATPath = ""

    init() {
        apn = defaults.string(forKey: "apn") ?? ""
        phone = defaults.string(forKey: "phone") ?? "*99#"
        username = defaults.string(forKey: "username") ?? ""
        autoConnect = defaults.bool(forKey: "autoConnect")

        engine.onTelemetry = { [weak self] value in
            DispatchQueue.main.async {
                self?.telemetry = value
            }
        }
        engine.onLog = { [weak self] text in
            DispatchQueue.main.async {
                self?.appendLog(text, level: .detail)
            }
        }
    }

    var atPort: String? {
        pcuiPort ?? modemPort
    }

    var canConnect: Bool {
        guard modemPort != nil else { return false }
        return link == .ready || link == .error
    }

    var canDisconnect: Bool {
        link == .connected || link == .connecting || link == .disconnecting
    }

    var isConnected: Bool { link == .connected }

    var portSummary: String {
        if let pcui = pcuiPort, let modem = modemPort {
            return "\(shortPort(modem)) + \(shortPort(pcui))"
        }
        if let modem = modemPort { return shortPort(modem) }
        if let pcui = pcuiPort { return shortPort(pcui) }
        return "No serial port"
    }

    func start() {
        guard !started else { return }
        started = true

        appendLog("Mobile Partner started", level: .info)
        refreshAll()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let online = self.helper.ping()
            DispatchQueue.main.async {
                self.helperOnline = online
                if !online {
                    self.appendLog("Privileged helper is not running (install the package, then reboot).", level: .error)
                }
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appendLog("Mac woke from sleep — refreshing modem", level: .detail)
            self?.refreshAll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        engine.close()
        started = false
    }

    // MARK: - Polling

    private func tick() {
        tickCount += 1
        refreshPorts()

        if tickCount % 4 == 0 {
            refreshHardware()
        }
        if tickCount % 20 == 0 {
            pingHelper()
        }
        if link.isActive {
            pollHelperStatus()
        }
        updateUptime()

        if tickCount % 3 == 0 {
            refreshTelemetry(full: false)
        }
        autoConnectIfNeeded()
    }

    func refreshAll() {
        refreshPorts(force: true)
        refreshHardware()
        pingHelper()
        refreshTelemetry(full: true)
        updateUptime()
    }

    private func refreshPorts(force: Bool = false) {
        let names = HardwareProbe.huaweiSerialPorts()
        let paths = names.map { "/dev/\($0)" }
        let signature = paths.joined(separator: "|")
        if !force && signature == lastPortSignature {
            return
        }
        lastPortSignature = signature

        let newPCUI = paths.first { $0.lowercased().contains("pcui") }
        let newModem = paths.first {
            $0.lowercased().contains("modem") && !$0.lowercased().contains("pcui")
        } ?? paths.first

        if newPCUI != pcuiPort {
            pcuiPort = newPCUI
            if let newPCUI {
                appendLog("AT port detected: \(shortPort(newPCUI))", level: .success)
            }
        }
        if newModem != modemPort {
            modemPort = newModem
            if let newModem {
                appendLog("Modem port detected: \(shortPort(newModem))", level: .success)
            }
        }

        if paths.isEmpty {
            engine.close()
            lastLoggedATPath = ""
            if usbDevices.isEmpty {
                if link != .error { link = .noModem }
            } else if !link.isActive {
                link = .driverInactive
            }
        } else if !link.isActive && (link == .noModem || link == .driverInactive) {
            link = .ready
        }

        syncATPort()
    }

    private func syncATPort() {
        var desired: String? = pcuiPort
        if desired == nil && !link.isActive {
            desired = modemPort
        }
        if desired == nil && link == .error && modemPort != nil {
            desired = modemPort
        }

        if let desired {
            if engine.serial.currentPath != desired {
                engine.close()
                if engine.open(path: desired) {
                    lastLoggedATPath = desired
                    refreshTelemetry(full: true)
                } else if lastLoggedATPath != desired {
                    lastLoggedATPath = desired
                    appendLog("Could not open \(shortPort(desired)); check that no other app is using it.", level: .error)
                }
            }
        } else if engine.serial.isOpen {
            engine.close()
        }
    }

    private func refreshHardware() {
        guard !hardwarePollInFlight else { return }
        hardwarePollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let devices = HardwareProbe.huaweiDevices()
            let driver = HardwareProbe.driverLoaded()
            DispatchQueue.main.async {
                self.hardwarePollInFlight = false
                if devices != self.usbDevices {
                    self.usbDevices = devices
                    if devices.isEmpty {
                        self.appendLog("Modem disconnected", level: .detail)
                    } else {
                        let names = devices.map { "\($0.displayName) [\(String(format: "%04x", $0.productID))]" }
                        self.appendLog("USB device: \(names.joined(separator: ", "))", level: .detail)
                    }
                    if !self.link.isActive {
                        if devices.isEmpty {
                            self.link = .noModem
                        } else if self.modemPort == nil {
                            self.link = .driverInactive
                        } else {
                            self.link = .ready
                        }
                    }
                    self.refreshPorts(force: true)
                }
                if driver != self.driverLoaded {
                    self.driverLoaded = driver
                    self.appendLog(driver ? "Huawei kernel driver is loaded" : "Huawei kernel driver is not loaded",
                                   level: driver ? .success : .error)
                }
            }
        }
    }

    private func pingHelper() {
        guard !helperPingInFlight else { return }
        helperPingInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let online = self.helper.ping()
            DispatchQueue.main.async {
                self.helperPingInFlight = false
                if online != self.helperOnline {
                    self.helperOnline = online
                    self.appendLog(online ? "Privileged helper connected" : "Privileged helper unavailable",
                                   level: online ? .success : .error)
                }
            }
        }
    }

    private func refreshTelemetry(full: Bool) {
        guard engine.serial.isOpen else { return }
        engine.refresh(full: full) { [weak self] value in
            self?.telemetry = value
        }
    }

    private func updateUptime() {
        guard let start = connectedSince else {
            uptimeText = "—"
            return
        }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        uptimeText = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    // MARK: - Connect / disconnect

    func toggleConnection() {
        if canDisconnect {
            disconnect()
        } else {
            connect()
        }
    }

    func connect() {
        guard !busy else { return }
        guard let modem = modemPort else {
            lastError = "No modem serial port is available."
            link = .error
            return
        }

        let cleanAPN = apn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAPN.isEmpty else {
            lastError = "Enter the APN provided by your mobile carrier."
            return
        }
        if !telemetry.simReady && telemetry.sim != "Unknown" {
            lastError = "The SIM is not ready (\(telemetry.sim))."
            return
        }
        if busy { return }

        busy = true
        lastError = nil
        link = .connecting
        connectStartedAt = Date()
        connectedSince = nil
        ipAddress = nil
        bytesIn = 0
        bytesOut = 0
        didAutoConnect = true
        appendLog("Connecting with APN “\(cleanAPN)”…", level: .info)

        let at = pcuiPort ?? modem
        let phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if !self.engine.serial.isOpen || self.engine.serial.currentPath != at {
                _ = self.engine.open(path: at)
            }
            let apnAccepted = self.engine.setAPN(cleanAPN)

            DispatchQueue.main.async {
                if !apnAccepted {
                    self.finishConnect(error: "The modem rejected the APN. Check the SIM and APN, then try again.")
                    return
                }

                let online = self.helper.ping()
                self.helperOnline = online
                guard online else {
                    self.finishConnect(error: "The privileged helper is not running. Reinstall Mobile Partner and reboot.")
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    let setup = self.helper.setup(apn: cleanAPN, phone: phone, username: user, password: pass)
                    guard let setup, setup.ok else {
                        let detail = setup?.detail ?? "The helper could not create the PPP service."
                        DispatchQueue.main.async { self.finishConnect(error: detail) }
                        return
                    }

                    let start = self.helper.connect()
                    DispatchQueue.main.async {
                        if let start, start.ok {
                            self.appendLog("PPP started — negotiating with the network", level: .detail)
                            if self.pcuiPort == nil {
                                self.engine.close()
                            }
                        } else {
                            self.finishConnect(error: start?.detail ?? "PPP could not be started.")
                        }
                    }
                }
            }
        }
    }

    func disconnect() {
        guard !busy else { return }
        guard link == .connected || link == .connecting || link == .disconnecting else { return }
        busy = true
        lastError = nil
        link = .disconnecting
        appendLog("Disconnecting…", level: .info)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let reply = self.helper.disconnect()
            DispatchQueue.main.async {
                self.busy = false
                if let reply, reply.ok {
                    self.link = .ready
                    self.connectedSince = nil
                    self.ipAddress = nil
                    self.appendLog("Disconnected", level: .detail)
                    self.syncATPort()
                } else if self.helperOnline {
                    self.finishConnect(error: reply?.detail ?? "Could not disconnect cleanly.")
                } else {
                    self.link = .ready
                    self.appendLog("Helper unavailable; the connection may already be down.", level: .error)
                }
            }
        }
    }

    private func finishConnect(error: String) {
        busy = false
        link = .error
        lastError = error
        connectedSince = nil
        appendLog(error, level: .error)
    }

    func retry() {
        lastError = nil
        if modemPort != nil {
            link = .ready
            refreshAll()
        } else {
            link = usbDevices.isEmpty ? .noModem : .driverInactive
            refreshAll()
        }
    }

    // MARK: - Helper status

    private func pollHelperStatus() {
        guard !statusPollInFlight else { return }
        statusPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let reply = self.helper.status()
            DispatchQueue.main.async {
                self.statusPollInFlight = false
                self.applyHelperStatus(reply)
            }
        }
    }

    private func applyHelperStatus(_ reply: HelperReply?) {
        guard let reply else {
            if link == .connecting, let started = connectStartedAt,
               Date().timeIntervalSince(started) > 25 {
                finishConnect(error: "The helper stopped responding while connecting.")
            } else if link == .connected {
                appendLog("Lost contact with the privileged helper", level: .error)
            }
            return
        }

        if let ip = reply.ip, !ip.isEmpty {
            ipAddress = ip
        }
        if reply.bytesIn > 0 || reply.bytesOut > 0 {
            bytesIn = reply.bytesIn
            bytesOut = reply.bytesOut
        }
        if !reply.ok, let detail = reply.detail, !detail.isEmpty {
            appendLog(detail, level: .error)
        }

        switch reply.status ?? "unknown" {
        case "connected":
            if link != .connected {
                link = .connected
                busy = false
                connectedSince = Date()
                appendLog("Connected" + (ipAddress.map { " — \($0)" } ?? ""), level: .success)
            }
        case "connecting":
            if link != .connecting {
                link = .connecting
                busy = true
            }
        case "disconnecting":
            if link != .disconnecting {
                link = .disconnecting
                busy = true
            }
        case "disconnected":
            if link == .connecting {
                if let started = connectStartedAt, Date().timeIntervalSince(started) > 35 {
                    finishConnect(error: "PPP negotiation failed. Check the APN and signal strength.")
                }
            } else if link == .connected {
                link = .ready
                busy = false
                connectedSince = nil
                ipAddress = nil
                appendLog("The mobile connection ended", level: .detail)
                syncATPort()
            } else if link == .disconnecting {
                link = .ready
                busy = false
                connectedSince = nil
                ipAddress = nil
                appendLog("Disconnected", level: .detail)
                syncATPort()
            }
        case "invalid":
            if link == .connected {
                link = .ready
                connectedSince = nil
                ipAddress = nil
            }
            if link == .connecting, let started = connectStartedAt,
               Date().timeIntervalSince(started) > 20 {
                finishConnect(error: "The network service is invalid. Try Connect again.")
            }
        default:
            break
        }
    }

    // MARK: - Modem mode / activation

    func activateModem() {
        guard !busy else { return }
        busy = true
        appendLog("Asking the modem to switch out of CD-ROM mode…", level: .info)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var detail: String?

            if self.helper.ping() {
                let reply = self.helper.activateModem()
                detail = reply?.detail
                if reply?.ok != true {
                    self.appendLogAsync(reply?.detail ?? "Helper could not run the activation tool.", level: .error)
                }
            }

            if detail == nil {
                if let url = Bundle.main.url(forResource: "MBBActivateApp", withExtension: nil) {
                    let process = Process()
                    process.executableURL = url
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    do {
                        try process.run()
                        process.waitUntilExit()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        detail = String(decoding: data, as: UTF8.self)
                    } catch {
                        detail = "Could not launch activation tool: \(error.localizedDescription)"
                    }
                } else {
                    detail = "Activation tool is missing from the app bundle."
                }
            }

            DispatchQueue.main.async {
                self.busy = false
                if let detail, !detail.isEmpty {
                    self.appendLog(detail.trimmingCharacters(in: .whitespacesAndNewlines), level: .detail)
                }
                self.appendLog("Waiting for the modem to re-enumerate…", level: .info)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.refreshAll()
                }
            }
        }
    }

    func resetService() {
        guard !busy else { return }
        busy = true
        appendLog("Removing the saved PPP service…", level: .info)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let reply = self.helper.removeService()
            DispatchQueue.main.async {
                self.busy = false
                if let reply, reply.ok {
                    self.appendLog("PPP service removed. It will be recreated on the next connection.", level: .detail)
                } else {
                    self.appendLog(reply?.detail ?? "Could not remove the PPP service.", level: .error)
                }
            }
        }
    }

    // MARK: - Diagnostics / log

    func copyDiagnostics() {
        var lines: [String] = []
        lines.append("Mobile Partner diagnostics")
        lines.append("Date: \(Date())")
        lines.append("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Link: \(link.title)")
        lines.append("USB devices: \(usbDevices.isEmpty ? "none" : usbDevices.map { "\($0.displayName) [\(String(format: "%04x", $0.productID))]" }.joined(separator: ", "))")
        lines.append("Serial ports: \(portSummary)")
        lines.append("PCUI: \(pcuiPort ?? "—")")
        lines.append("Modem: \(modemPort ?? "—")")
        lines.append("Driver loaded: \(driverLoaded)")
        lines.append("Helper online: \(helperOnline)")
        lines.append("APN: \(apn)")
        lines.append("Telemetry: model=\(telemetry.model) firmware=\(telemetry.firmware) imei=\(telemetry.imei)")
        lines.append("SIM: \(telemetry.sim) registration=\(telemetry.registration) signal=\(telemetry.signalRaw) operator=\(telemetry.operatorName)")
        lines.append("IP: \(ipAddress ?? "—") bytesIn=\(bytesIn) bytesOut=\(bytesOut)")
        if let lastError { lines.append("Last error: \(lastError)") }
        lines.append("")
        lines.append("Recent log:")
        for entry in log.suffix(80) {
            lines.append("\(entry.date)  \(entry.text)")
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog("Diagnostics copied to the clipboard", level: .detail)
    }

    func clearLog() {
        log.removeAll()
    }

    private func appendLogAsync(_ text: String, level: LogEntry.Level) {
        DispatchQueue.main.async { [weak self] in
            self?.appendLog(text, level: level)
        }
    }

    func appendLog(_ text: String, level: LogEntry.Level) {
        log.append(LogEntry(text: text, level: level))
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }

    private func shortPort(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Auto-connect

    private func autoConnectIfNeeded() {
        guard autoConnect, !didAutoConnect, link == .ready, telemetry.simReady else { return }
        let cleanAPN = apn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAPN.isEmpty else { return }
        didAutoConnect = true
        appendLog("Auto-connect is enabled", level: .detail)
        connect()
    }
}
