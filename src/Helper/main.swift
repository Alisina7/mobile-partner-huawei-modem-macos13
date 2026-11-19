import Foundation
import SystemConfiguration
import Darwin

// MARK: - Constants and logging

let socketPath = ProcessInfo.processInfo.environment["MP_SOCKET"] ?? "/var/run/mobilepartner.sock"
let serviceName = "Mobile Partner"
let modemScriptName = "HUAWEI Mobile Connect - 3G Modem"
let stateDirectory = ProcessInfo.processInfo.environment["MP_STATE"] ?? "/usr/local/mobilepartner"
let serviceIDPath = stateDirectory + "/service.id"
let logPath = ProcessInfo.processInfo.environment["MP_LOG"] ?? "/var/log/mobilepartner.log"

private let logHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [
            .posixPermissions: 0o644
        ])
    }
    let handle = FileHandle(forWritingAtPath: logPath)
    handle?.seekToEndOfFile()
    return handle
}()

func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date()))  \(message)\n"
    if let data = line.data(using: .utf8) {
        logHandle?.write(data)
    }
    NSLog("MobilePartnerHelper: %@", message)
}

func cleanInput(_ value: String, limit: Int) -> String {
    let cleaned = value
        .replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(cleaned.prefix(limit))
}

func systemConfigurationError() -> String {
    let code = SCError()
    return String(cString: SCErrorString(code))
}

func cfString(_ value: String?) -> String {
    value ?? ""
}

// MARK: - Service discovery

func bsdName(of interface: SCNetworkInterface?) -> String {
    guard let interface else { return "" }
    return cfString(SCNetworkInterfaceGetBSDName(interface) as String?)
}

func interfaceType(of interface: SCNetworkInterface?) -> String {
    guard let interface else { return "" }
    return cfString(SCNetworkInterfaceGetInterfaceType(interface) as String?)
}

func interfaceSummary() -> String {
    guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
        return "SystemConfiguration returned no interfaces."
    }
    let pieces = interfaces.map { iface -> String in
        let type = interfaceType(of: iface)
        let bsd = bsdName(of: iface)
        let name = cfString(SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?)
        return "\(type)/\(name)/\(bsd)"
    }
    return "Interfaces: " + pieces.joined(separator: ", ")
}

func findModemInterface() -> SCNetworkInterface? {
    guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
        return nil
    }
    for iface in interfaces {
        let bsd = bsdName(of: iface).lowercased()
        let name = cfString(SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?).lowercased()
        if bsd.contains("huawei") || name.contains("huawei") {
            return iface
        }
    }
    return nil
}

func waitForModemInterface(seconds: TimeInterval = 10) -> SCNetworkInterface? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let iface = findModemInterface() { return iface }
        Thread.sleep(forTimeInterval: 0.5)
    } while Date() < deadline
    return nil
}

func serviceDeviceName(_ service: SCNetworkService) -> String {
    bsdName(of: SCNetworkServiceGetInterface(service))
}

// MARK: - PPP manager

final class PPPManager {
    static let shared = PPPManager()

    private var connection: SCNetworkConnection?
    private var serviceID: String?
    private var lastStatus: SCNetworkConnectionStatus = SCNetworkConnectionStatus.disconnected
    private var lastIP: String?
    private var lastStart: Date?

    private init() {
        if let saved = try? String(contentsOfFile: serviceIDPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            serviceID = saved
        }
    }

    func setup(apn rawAPN: String, phone rawPhone: String,
               username rawUsername: String, password rawPassword: String) -> (Bool, String) {
        let apn = cleanInput(rawAPN, limit: 100)
        let phone = cleanInput(rawPhone.isEmpty ? "*99#" : rawPhone, limit: 40)
        let username = cleanInput(rawUsername, limit: 100)
        let password = cleanInput(rawPassword, limit: 100)

        guard !apn.isEmpty else {
            return (false, "The APN is empty.")
        }

        guard let prefs = SCPreferencesCreate(nil, "MobilePartnerHelper" as CFString, nil) else {
            return (false, "Could not open the system network preferences.")
        }
        if !SCPreferencesLock(prefs, true) {
            return (false, "Could not lock the system network preferences: \(systemConfigurationError())")
        }
        defer { SCPreferencesUnlock(prefs) }

        let allServices = (SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]) ?? []
        let namedServices = allServices.filter {
            cfString(SCNetworkServiceGetName($0) as String?) == serviceName
        }

        var selected: SCNetworkService?
        for candidate in namedServices {
            let device = serviceDeviceName(candidate).lowercased()
            if device.contains("huawei") {
                selected = candidate
                break
            }
        }
        if selected == nil { selected = namedServices.first }

        // Remove duplicates.
        for extra in namedServices where extra !== selected {
            _ = SCNetworkServiceRemove(extra)
        }

        if let existing = selected {
            let device = serviceDeviceName(existing).lowercased()
            if !device.contains("huawei") {
                log("Removing stale service with interface '\(device)'")
                _ = SCNetworkServiceRemove(existing)
                selected = nil
            }
        }

        if selected == nil {
            guard let modemInterface = waitForModemInterface() else {
                log("No modem interface found. \(interfaceSummary())")
                return (false, "The HUAWEI serial modem was not found. If the driver was just installed, reboot macOS first. \(interfaceSummary())")
            }
            log("Using modem interface \(interfaceType(of: modemInterface))/\(bsdName(of: modemInterface))")

            guard let pppInterface = SCNetworkInterfaceCreateWithInterface(
                modemInterface, kSCNetworkInterfaceTypePPP
            ) else {
                return (false, "Could not layer PPP over \(bsdName(of: modemInterface)).")
            }

            guard let service = SCNetworkServiceCreate(prefs, pppInterface) else {
                return (false, "Could not create the network service: \(systemConfigurationError())")
            }
            SCNetworkServiceSetName(service, serviceName as CFString)
            SCNetworkServiceEstablishDefaultConfiguration(service)
            selected = service
        }

        guard let service = selected else {
            return (false, "Could not prepare the network service.")
        }

        if !SCNetworkServiceGetEnabled(service) {
            SCNetworkServiceSetEnabled(service, true)
        }
        if let set = SCNetworkSetCopyCurrent(prefs) {
            _ = SCNetworkSetAddService(set, service)
        }

        configure(service: service, apn: apn, phone: phone,
                  username: username, password: password)

        if let protocols = SCNetworkServiceCopyProtocols(service) as? [SCNetworkProtocol] {
            let types = protocols.compactMap { SCNetworkProtocolGetProtocolType($0) as String? }
            log("Service protocols: \(types.joined(separator: ", "))")
        }

        guard SCPreferencesCommitChanges(prefs) else {
            return (false, "Could not save network preferences: \(systemConfigurationError())")
        }
        guard SCPreferencesApplyChanges(prefs) else {
            return (false, "Could not apply network preferences: \(systemConfigurationError())")
        }

        guard let sid = SCNetworkServiceGetServiceID(service) as String? else {
            return (false, "The network service has no identifier.")
        }
        serviceID = sid
        writeServiceID(sid)
        connection = nil
        lastStatus = SCNetworkConnectionStatus.disconnected
        lastIP = nil
        log("PPP service ready (\(sid)), APN '\(apn)', number '\(phone)'")
        return (true, "PPP service ready")
    }

    private func configure(service: SCNetworkService, apn: String, phone: String,
                           username: String, password: String) {
        if let ppp = SCNetworkServiceCopyProtocol(service, kSCEntNetPPP) {
            var config = (SCNetworkProtocolGetConfiguration(ppp) as? [String: Any]) ?? [:]
            config[kSCPropNetPPPCommRemoteAddress as String] = phone
            config[kSCPropNetPPPCommDisplayTerminalWindow as String] = 0
            config[kSCPropNetPPPCommUseTerminalScript as String] = 0
            config[kSCPropNetPPPCommRedialEnabled as String] = 0
            config[kSCPropNetPPPAuthProtocol as String] = ["CHAP", "PAP"]
            if !username.isEmpty {
                config[kSCPropNetPPPAuthName as String] = username
                config[kSCPropNetPPPAuthPassword as String] = password
            }
            if !SCNetworkProtocolSetConfiguration(ppp, config as CFDictionary) {
                log("Could not set PPP configuration: \(systemConfigurationError())")
            }
        } else {
            log("Warning: service has no PPP protocol")
        }

        if let modem = SCNetworkServiceCopyProtocol(service, kSCEntNetModem) {
            var config = (SCNetworkProtocolGetConfiguration(modem) as? [String: Any]) ?? [:]
            config[kSCPropNetModemConnectionScript as String] = modemScriptName
            config[kSCPropNetModemAccessPointName as String] = apn
            config[kSCPropNetModemDeviceVendor as String] = "HUAWEI"
            config[kSCPropNetModemDialMode as String] = kSCValNetModemDialModeIgnoreDialTone as String
            config[kSCPropNetModemSpeed as String] = 115200
            if !SCNetworkProtocolSetConfiguration(modem, config as CFDictionary) {
                log("Could not set modem configuration: \(systemConfigurationError())")
            }
        } else {
            log("Warning: service has no Modem protocol")
        }

        if let ipv4 = SCNetworkServiceCopyProtocol(service, kSCEntNetIPv4) {
            var config = (SCNetworkProtocolGetConfiguration(ipv4) as? [String: Any]) ?? [:]
            config[kSCPropNetIPv4ConfigMethod as String] = kSCValNetIPv4ConfigMethodPPP as String
            if !SCNetworkProtocolSetConfiguration(ipv4, config as CFDictionary) {
                log("Could not set IPv4 configuration: \(systemConfigurationError())")
            }
        }
    }

    private func writeServiceID(_ sid: String) {
        try? FileManager.default.createDirectory(
            atPath: stateDirectory, withIntermediateDirectories: true
        )
        try? sid.write(toFile: serviceIDPath, atomically: true, encoding: .utf8)
    }

    private func ensureConnection() -> SCNetworkConnection? {
        if let connection { return connection }
        guard let serviceID else { return nil }
        var context = SCNetworkConnectionContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let newConnection = SCNetworkConnectionCreateWithServiceID(
            nil, serviceID as CFString, nil, &context
        ) else {
            log("Could not create SCNetworkConnection for \(serviceID)")
            return nil
        }
        connection = newConnection
        return newConnection
    }

    func connect() -> (Bool, String) {
        if currentStatus() == "connected" {
            return (true, "Already connected")
        }
        guard let connection = ensureConnection() else {
            return (false, "No PPP service is configured yet.")
        }
        if SCNetworkConnectionStart(connection, nil, true) {
            lastStatus = SCNetworkConnectionStatus.connecting
            lastStart = Date()
            log("PPP start requested")
            return (true, "Connecting")
        }
        return (false, "PPP start failed: \(systemConfigurationError())")
    }

    func disconnect() -> (Bool, String) {
        guard let connection = ensureConnection() else {
            return (true, "Not connected")
        }
        if SCNetworkConnectionStop(connection, true) {
            lastStatus = SCNetworkConnectionStatus.disconnecting
            log("PPP stop requested")
            return (true, "Disconnecting")
        }
        return (false, "PPP stop failed: \(systemConfigurationError())")
    }

    func currentStatus() -> String {
        if let connection {
            let live = SCNetworkConnectionGetStatus(connection)
            if live != SCNetworkConnectionStatus.invalid {
                lastStatus = live
            }
        }

        // Right after start, SystemConfiguration can briefly report invalid.
        if lastStatus == SCNetworkConnectionStatus.invalid,
           let lastStart, Date().timeIntervalSince(lastStart) < 8 {
            return "connecting"
        }

        switch lastStatus {
        case SCNetworkConnectionStatus.connected:
            if lastIP == nil { lastIP = ipAddress() }
            return "connected"
        case SCNetworkConnectionStatus.connecting:
            return "connecting"
        case SCNetworkConnectionStatus.disconnecting:
            return "disconnecting"
        case SCNetworkConnectionStatus.disconnected:
            lastIP = nil
            return "disconnected"
        default:
            if let lastStart, Date().timeIntervalSince(lastStart) < 8 {
                return "connecting"
            }
            return "invalid"
        }
    }

    func ipAddress() -> String? {
        guard let serviceID else { return nil }
        guard let store = SCDynamicStoreCreate(nil, "MobilePartnerHelper" as CFString, nil, nil) else {
            return nil
        }
        let key = "State:/Network/Service/\(serviceID)/IPv4" as CFString
        if let value = SCDynamicStoreCopyValue(store, key) as? [String: Any] {
            if let addresses = value["Addresses"] as? [String], let first = addresses.first {
                return first
            }
            if let address = value["Address"] as? String {
                return address
            }
        }
        return nil
    }

    func statistics() -> (Int64, Int64) {
        guard let connection,
              let raw = SCNetworkConnectionCopyStatistics(connection) as? [String: Any] else {
            return (0, 0)
        }
        func number(_ key: String, in dict: [String: Any]) -> Int64 {
            (dict[key] as? NSNumber)?.int64Value ?? 0
        }
        var bytesIn = number("BytesIn", in: raw)
        var bytesOut = number("BytesOut", in: raw)
        if bytesIn == 0 && bytesOut == 0,
           let nested = raw["PPP"] as? [String: Any] {
            bytesIn = number("BytesIn", in: nested)
            bytesOut = number("BytesOut", in: nested)
        }
        return (bytesIn, bytesOut)
    }

    func removeService() -> (Bool, String) {
        guard let prefs = SCPreferencesCreate(nil, "MobilePartnerHelper" as CFString, nil) else {
            return (false, "Could not open network preferences.")
        }
        if !SCPreferencesLock(prefs, true) {
            return (false, "Could not lock network preferences.")
        }
        defer { SCPreferencesUnlock(prefs) }

        if let connection {
            _ = SCNetworkConnectionStop(connection, true)
        }
        connection = nil
        lastStatus = SCNetworkConnectionStatus.disconnected
        lastIP = nil

        if let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            for service in services {
                if cfString(SCNetworkServiceGetName(service) as String?) == serviceName {
                    log("Removing service \(cfString(SCNetworkServiceGetServiceID(service) as String?))")
                    _ = SCNetworkServiceRemove(service)
                }
            }
        }
        _ = SCPreferencesCommitChanges(prefs)
        _ = SCPreferencesApplyChanges(prefs)

        serviceID = nil
        try? FileManager.default.removeItem(atPath: serviceIDPath)
        return (true, "PPP service removed")
    }

    func statusPayload() -> [String: Any] {
        let status = currentStatus()
        let (bytesIn, bytesOut) = statistics()
        var payload: [String: Any] = [
            "ok": true,
            "status": status,
            "bytesIn": bytesIn,
            "bytesOut": bytesOut
        ]
        if let serviceID { payload["serviceID"] = serviceID }
        if status == "connected", let ip = lastIP ?? ipAddress() {
            payload["ip"] = ip
        }
        return payload
    }
}

// MARK: - Server

final class HelperServer {
    private let queue = DispatchQueue(label: "com.mobilepartner.helper.server")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    func start() {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes.prefix(raw.count))
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length)
            }
        }
        guard bound == 0 else {
            log("bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        chmod(socketPath, 0o660)
        if let group = getgrnam("admin") {
            chown(socketPath, 0, group.pointee.gr_gid)
        } else {
            chmod(socketPath, 0o666)
        }

        guard listen(fd, 16) == 0 else {
            log("listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        readSource.setCancelHandler {
            close(fd)
        }
        readSource.resume()
        source = readSource
        log("Helper listening on \(socketPath)")
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        handle(client: client)
    }

    private func handle(client: Int32) {
        defer { close(client) }

        var timeout = timeval(tv_sec: 45, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let count = read(client, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if data.contains(0x0A) { break }
            } else {
                break
            }
        }

        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = request["cmd"] as? String else {
            send(client, ["ok": false, "detail": "Malformed request"])
            return
        }

        log("Command: \(command)")

        switch command {
        case "ping":
            send(client, ["ok": true, "detail": "helper ready", "version": "1.0"])

        case "setup":
            let result = PPPManager.shared.setup(
                apn: request["apn"] as? String ?? "",
                phone: request["phone"] as? String ?? "*99#",
                username: request["username"] as? String ?? "",
                password: request["password"] as? String ?? ""
            )
            send(client, ["ok": result.0, "detail": result.1])

        case "connect":
            let result = PPPManager.shared.connect()
            var payload: [String: Any] = ["ok": result.0, "detail": result.1]
            if result.0 {
                payload["status"] = PPPManager.shared.currentStatus()
            }
            send(client, payload)

        case "disconnect":
            let result = PPPManager.shared.disconnect()
            send(client, ["ok": result.0, "detail": result.1, "status": PPPManager.shared.currentStatus()])

        case "status":
            send(client, PPPManager.shared.statusPayload())

        case "remove":
            let result = PPPManager.shared.removeService()
            send(client, ["ok": result.0, "detail": result.1])

        case "activate":
            let result = runActivationTool()
            send(client, ["ok": result.0, "detail": result.1])

        default:
            send(client, ["ok": false, "detail": "Unknown command"])
        }
    }

    private func runActivationTool() -> (Bool, String) {
        let path = stateDirectory + "/MBBActivateApp"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return (false, "Activation tool is missing at \(path).")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = text.isEmpty ? "Modem activation requested." : text
            return (process.terminationStatus == 0, detail)
        } catch {
            return (false, "Could not run activation tool: \(error.localizedDescription)")
        }
    }

    private func send(_ client: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        var offset = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < data.count {
                let written = write(client, base + offset, data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var pfd = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 500) <= 0 { return }
                } else {
                    return
                }
            }
        }
    }
}

// MARK: - Entry point

try? FileManager.default.createDirectory(
    atPath: stateDirectory, withIntermediateDirectories: true
)

signal(SIGPIPE, SIG_IGN)
log("Helper starting (uid \(getuid()))")

let server = HelperServer()
server.start()

dispatchMain()
