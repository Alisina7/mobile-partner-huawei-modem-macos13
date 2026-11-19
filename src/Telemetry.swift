import Foundation

struct Telemetry {
    var model = ""
    var firmware = ""
    var imei = ""
    var sim = "Unknown"
    var signalRaw = 99
    var registration = "Not registered"
    var roaming = false
    var operatorName = ""
    var modemAPN = ""
    var packetAttached = false
    var lastUpdated = Date.distantPast

    var signalBars: Int {
        guard signalRaw >= 0 && signalRaw <= 31 && signalRaw != 99 else { return 0 }
        if signalRaw == 0 { return 0 }
        return max(1, min(5, Int(ceil(Double(signalRaw) / 31.0 * 5.0))))
    }

    var signalDBm: Int? {
        guard signalRaw >= 0 && signalRaw <= 31 && signalRaw != 99 else { return nil }
        return -113 + (2 * signalRaw)
    }

    var signalQuality: String {
        guard let dbm = signalDBm else { return "No signal" }
        switch dbm {
        case (-70)...: return "Excellent"
        case (-85)..<(-70): return "Good"
        case (-100)..<(-85): return "Fair"
        default: return "Weak"
        }
    }

    var isRegistered: Bool {
        registration == "Registered" || registration == "Roaming"
    }

    var simReady: Bool { sim == "Ready" }
}

final class ATEngine {
    let serial = ATSerial()

    private let queue = DispatchQueue(label: "com.mobilepartner.atengine")
    private var cached = Telemetry()
    private var lastSIM: String?
    private var lastRegistration: String?

    var onTelemetry: ((Telemetry) -> Void)?
    var onLog: ((String) -> Void)?

    func open(path: String) -> Bool {
        let opened = serial.open(path)
        if opened {
            onLog?("AT port open: \(path)")
        }
        return opened
    }

    func close() {
        serial.close()
    }

    @discardableResult
    func setAPN(_ apn: String) -> Bool {
        let clean = apn.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let response = serial.command("AT+CGDCONT=1,\"IP\",\"\(clean)\"", timeout: 4)
        if !response.isOK {
            onLog?("Could not write APN to modem (\(response.final))")
            return false
        }
        return true
    }

    func refresh(full: Bool, completion: @escaping (Telemetry) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.serial.isOpen else {
                DispatchQueue.main.async { completion(self.cached) }
                return
            }

            var current = self.cached

            if full {
                _ = self.serial.command("ATE0", timeout: 1)
                _ = self.serial.command("AT", timeout: 1)

                if let model = self.simpleValue(command: "AT+CGMM", timeout: 2), !model.isEmpty {
                    current.model = model
                }
                if let firmware = self.simpleValue(command: "AT+CGMR", timeout: 2), !firmware.isEmpty {
                    current.firmware = firmware
                }
                if let imei = self.imei(), !imei.isEmpty {
                    current.imei = imei
                }
                if current.model.isEmpty {
                    let ati = self.serial.command("ATI", timeout: 3)
                    if let first = ati.lines.first(where: {
                        !$0.uppercased().hasPrefix("ATI") && !$0.hasPrefix("+")
                    }) {
                        current.model = first
                    }
                }
            }

            if let sim = self.simState() {
                current.sim = sim
                if sim != self.lastSIM {
                    self.lastSIM = sim
                    DispatchQueue.main.async {
                        self.onLog?("SIM: \(sim)")
                    }
                }
            }

            if let raw = self.signalRaw() {
                current.signalRaw = raw
            }

            if let registration = self.registrationState() {
                current.registration = registration.name
                current.roaming = registration.roaming
                if registration.name != self.lastRegistration {
                    self.lastRegistration = registration.name
                    DispatchQueue.main.async {
                        self.onLog?("Network: \(registration.name)")
                    }
                }
            }

            if let operatorName = self.operatorName(), !operatorName.isEmpty {
                current.operatorName = operatorName
            }
            if let apn = self.configuredAPN() {
                current.modemAPN = apn
            }
            if let attached = self.packetAttachedState() {
                current.packetAttached = attached
            }

            current.lastUpdated = Date()
            self.cached = current

            DispatchQueue.main.async {
                completion(current)
            }
        }
    }

    // MARK: - Parsers

    private func simpleValue(command: String, timeout: TimeInterval) -> String? {
        let response = serial.command(command, timeout: timeout)
        guard response.isOK else { return nil }
        return response.lines.first(where: { line in
            let upper = line.uppercased()
            return !upper.hasPrefix(command.uppercased())
                && !line.hasPrefix("+")
                && !upper.hasPrefix("AT")
        })
    }

    private func imei() -> String? {
        let response = serial.command("AT+CGSN", timeout: 3)
        for line in response.allLines {
            let digits = line.filter { $0.isNumber }
            if digits.count >= 14 && digits.count <= 17 && digits == line {
                return digits
            }
        }
        return nil
    }

    private func simState() -> String? {
        let response = serial.command("AT+CPIN?", timeout: 2)
        if let line = response.lines.first(where: { $0.hasPrefix("+CPIN:") }) {
            let value = line.replacingOccurrences(of: "+CPIN:", with: "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            if value == "READY" { return "Ready" }
            if value.contains("SIM PIN") { return "PIN required" }
            if value.contains("SIM PUK") { return "PUK required" }
            return value.capitalized
        }
        if response.final.hasPrefix("+CME ERROR") {
            if response.final.contains("10") { return "SIM not inserted" }
            if response.final.contains("11") { return "PIN required" }
            if response.final.contains("12") { return "PUK required" }
            if response.final.contains("13") { return "SIM failure" }
            return "SIM error"
        }
        return nil
    }

    private func signalRaw() -> Int? {
        let response = serial.command("AT+CSQ", timeout: 2)
        guard let line = response.lines.first(where: { $0.hasPrefix("+CSQ:") }) else {
            return nil
        }
        let value = line.replacingOccurrences(of: "+CSQ:", with: "")
            .split(separator: ",")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return value.flatMap(Int.init)
    }

    private func registrationState() -> (name: String, roaming: Bool)? {
        for command in ["AT+CREG?", "AT+CGREG?"] {
            let response = serial.command(command, timeout: 2)
            guard let line = response.lines.first(where: {
                $0.hasPrefix("+CREG:") || $0.hasPrefix("+CGREG:")
            }) else { continue }

            let pieces = line
                .replacingOccurrences(of: "+CREG:", with: "")
                .replacingOccurrences(of: "+CGREG:", with: "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let statusText = pieces.count >= 2 ? pieces[1] : pieces[0]
            guard let status = Int(statusText) else { continue }
            switch status {
            case 1: return ("Registered", false)
            case 2: return ("Searching", false)
            case 3: return ("Registration denied", false)
            case 4: return ("Unknown", false)
            case 5: return ("Roaming", true)
            default: return ("Not registered", false)
            }
        }
        return nil
    }

    private func operatorName() -> String? {
        let response = serial.command("AT+COPS?", timeout: 5)
        guard let line = response.lines.first(where: { $0.hasPrefix("+COPS:") }) else {
            return nil
        }
        return Self.quotedStrings(line).first
    }

    private func configuredAPN() -> String? {
        let response = serial.command("AT+CGDCONT?", timeout: 3)
        guard let line = response.lines.first(where: { $0.hasPrefix("+CGDCONT:") }) else {
            return nil
        }
        let strings = Self.quotedStrings(line)
        return strings.count >= 2 ? strings[1] : nil
    }

    private func packetAttachedState() -> Bool? {
        let response = serial.command("AT+CGATT?", timeout: 2)
        guard let line = response.lines.first(where: { $0.hasPrefix("+CGATT:") }) else {
            return nil
        }
        let value = line.replacingOccurrences(of: "+CGATT:", with: "")
            .trimmingCharacters(in: .whitespaces)
        return value == "1"
    }

    private static func quotedStrings(_ text: String) -> [String] {
        var result: [String] = []
        var current: String?
        for character in text {
            if character == "\"" {
                if let value = current {
                    result.append(value)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(character)
            }
        }
        return result
    }
}
