import Foundation
import Darwin

struct ATResponse {
    let lines: [String]
    let final: String

    var isOK: Bool { final == "OK" }
    var isError: Bool {
        final == "ERROR" || final.hasPrefix("+CME ERROR") || final.hasPrefix("+CMS ERROR")
    }
    var allLines: [String] { lines + [final] }
}

/// A small, synchronous AT command engine for a macOS serial device.
/// All access is serialized on a private queue so the UI and the poller can
/// safely share one port.
final class ATSerial {
    private let queue = DispatchQueue(label: "com.mobilepartner.atserial")
    private var fd: Int32 = -1
    private var openPath = ""

    var isOpen: Bool { queue.sync { fd >= 0 } }
    var currentPath: String { queue.sync { openPath } }

    @discardableResult
    func open(_ path: String) -> Bool {
        queue.sync {
            closeLocked()

            let newFD = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard newFD >= 0 else { return false }

            // Keep a second instance of the app from fighting over the same AT port.
            guard flock(newFD, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(newFD)
                return false
            }

            var tio = termios()
            guard tcgetattr(newFD, &tio) == 0 else {
                Darwin.close(newFD)
                return false
            }

            cfmakeraw(&tio)
            cfsetspeed(&tio, speed_t(B115200))
            tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
            tio.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CRTSCTS)
            tio.c_cflag = (tio.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
            tio.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
            tio.c_oflag = 0
            tio.c_lflag = 0
            withUnsafeMutableBytes(of: &tio.c_cc) { raw in
                raw[Int(VMIN)] = 0
                raw[Int(VTIME)] = 0
            }

            guard tcsetattr(newFD, TCSANOW, &tio) == 0 else {
                Darwin.close(newFD)
                return false
            }
            tcflush(newFD, TCIOFLUSH)

            fd = newFD
            openPath = path
            return true
        }
    }

    func close() {
        queue.sync { closeLocked() }
    }

    private func closeLocked() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        openPath = ""
    }

    /// Send one command and wait for a final result code.
    /// The returned `lines` contain everything before the final code.
    func command(_ command: String, timeout: TimeInterval = 2.0) -> ATResponse {
        queue.sync {
            guard fd >= 0 else {
                return ATResponse(lines: [], final: "NOPORT")
            }

            // Drop any unsolicited messages that arrived since the last command.
            drainLocked()

            guard writeAllLocked(Data((command + "\r").utf8)) else {
                return ATResponse(lines: [], final: "WRITE-ERROR")
            }

            var collected: [String] = []
            var buffer = Data()
            let deadline = Date().addingTimeInterval(timeout)

            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }

                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let slice = min(remaining, 0.5)
                let pollResult = poll(&pfd, 1, Int32(slice * 1000))
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if pollResult == 0 { continue }

                var chunk = [UInt8](repeating: 0, count: 1024)
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count > 0 {
                    buffer.append(chunk, count: count)
                } else if count == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }

                for line in extractLines(from: &buffer) {
                    if let final = finalCode(for: line) {
                        return ATResponse(lines: collected, final: final)
                    }
                    collected.append(line)
                }
            }

            // A final result code can arrive without a trailing newline.
            let leftover = String(decoding: buffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !leftover.isEmpty {
                if let final = finalCode(for: leftover) {
                    return ATResponse(lines: collected, final: final)
                }
                collected.append(leftover)
            }
            return ATResponse(lines: collected, final: "TIMEOUT")
        }
    }

    private func extractLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let slice = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            var line = String(decoding: slice, as: UTF8.self)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    private func finalCode(for line: String) -> String? {
        if line == "OK" || line == "ERROR" { return line }
        if line.hasPrefix("+CME ERROR") || line.hasPrefix("+CMS ERROR") { return line }
        if line.hasPrefix("CONNECT") { return line }
        for code in ["NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE", "COMMAND NOT SUPPORT"] {
            if line.hasPrefix(code) { return code }
        }
        return nil
    }

    @discardableResult
    private func writeAllLocked(_ data: Data) -> Bool {
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

    private func drainLocked() {
        guard fd >= 0 else { return }
        var scratch = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(fd, &scratch, scratch.count)
            if count <= 0 { break }
        }
    }

    deinit {
        close()
    }
}
