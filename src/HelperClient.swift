import Foundation
import Darwin

struct HelperReply {
    let ok: Bool
    let status: String?
    let detail: String?
    let serviceID: String?
    let ip: String?
    let bytesIn: Int64
    let bytesOut: Int64

    init?(object: [String: Any]) {
        ok = (object["ok"] as? Bool) ?? false
        status = object["status"] as? String
        detail = object["detail"] as? String
        serviceID = object["serviceID"] as? String
        ip = object["ip"] as? String
        bytesIn = (object["bytesIn"] as? NSNumber)?.int64Value ?? 0
        bytesOut = (object["bytesOut"] as? NSNumber)?.int64Value ?? 0
    }
}

/// Unix-domain client for the privileged Mobile Partner helper daemon.
final class HelperClient {
    static let socketPath = "/var/run/mobilepartner.sock"

    func ping() -> Bool {
        call(["cmd": "ping"], timeout: 2)?.ok ?? false
    }

    func setup(apn: String, phone: String, username: String, password: String) -> HelperReply? {
        call([
            "cmd": "setup",
            "apn": apn,
            "phone": phone,
            "username": username,
            "password": password
        ], timeout: 20)
    }

    func connect() -> HelperReply? {
        call(["cmd": "connect"], timeout: 20)
    }

    func disconnect() -> HelperReply? {
        call(["cmd": "disconnect"], timeout: 20)
    }

    func status() -> HelperReply? {
        call(["cmd": "status"], timeout: 4)
    }

    func activateModem() -> HelperReply? {
        call(["cmd": "activate"], timeout: 30)
    }

    func removeService() -> HelperReply? {
        call(["cmd": "remove"], timeout: 10)
    }

    func call(_ request: [String: Any], timeout: TimeInterval = 8) -> HelperReply? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes.prefix(raw.count))
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard connected == 0 else { return nil }

        guard let json = try? JSONSerialization.data(withJSONObject: request) else {
            return nil
        }
        var payload = json
        payload.append(0x0A)
        guard writeAll(fd: fd, data: payload) else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
            } else {
                break
            }
        }

        guard !response.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            return nil
        }
        return HelperReply(object: object)
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        var success = true
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                success = false
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base + offset, data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 500) <= 0 {
                        success = false
                        return
                    }
                } else {
                    success = false
                    return
                }
            }
        }
        return success
    }
}
