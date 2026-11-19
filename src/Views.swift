import SwiftUI
import AppKit

enum Theme {
    static let accent = Color(red: 0.24, green: 0.86, blue: 0.74)
    static let blue = Color(red: 0.34, green: 0.68, blue: 1.00)
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.54)
    static let tertiary = Color.white.opacity(0.32)
    static let card = Color.white.opacity(0.055)
    static let cardStrong = Color.white.opacity(0.085)
    static let stroke = Color.white.opacity(0.09)
    static let danger = Color(red: 1.00, green: 0.44, blue: 0.44)
    static let warning = Color(red: 1.00, green: 0.76, blue: 0.38)
}

struct ContentView: View {
    @ObservedObject var model: ModemModel

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 10) {
                HeaderView(model: model)
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        ConnectionCard(model: model)
                        QuickHelpCard(model: model)
                    }
                    VStack(spacing: 12) {
                        SignalCard(model: model)
                        NetworkCard(model: model)
                        DeviceCard(model: model)
                    }
                }
                LogView(model: model)
                FooterView(model: model)
            }
            .padding(16)
        }
        .frame(minWidth: 880, minHeight: 700)
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.055, blue: 0.072)
            RadialGradient(
                colors: [Color(red: 0.03, green: 0.30, blue: 0.29).opacity(0.55), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color(red: 0.08, green: 0.16, blue: 0.38).opacity(0.40), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 760
            )
        }
        .ignoresSafeArea()
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.25)
                    .foregroundColor(Theme.secondary)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var model: ModemModel

    private var appIcon: NSImage {
        NSApp.applicationIconImage
            ?? NSImage(systemSymbolName: "wifi.router", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 48, height: 48))
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Mobile Partner")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.text)
                Text("HUAWEI E1550 · 3G modem")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.secondary)
            }

            Spacer()

            StatusPill(state: model.link, busy: model.busy)

            Button {
                model.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh modem status")

            Menu {
                Button("Refresh") { model.refreshAll() }
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Divider()
                Button("Remove PPP Service") { model.resetService() }
                    .disabled(model.busy || model.isConnected)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.secondary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.06)))
            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
    }
}

struct StatusPill: View {
    let state: LinkState
    let busy: Bool

    private var color: Color {
        switch state {
        case .connected: return Theme.accent
        case .ready: return Theme.blue
        case .connecting, .disconnecting, .driverInactive: return Theme.warning
        case .error: return Theme.danger
        case .noModem: return Theme.secondary
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(state.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 1))
    }
}

// MARK: - Connection

struct ConnectionCard: View {
    @ObservedObject var model: ModemModel

    private var statusColor: Color {
        switch model.link {
        case .connected: return Theme.accent
        case .error: return Theme.danger
        case .connecting, .disconnecting, .driverInactive: return Theme.warning
        default: return Theme.secondary
        }
    }

    var body: some View {
        Card(title: "Connection", icon: "bolt.horizontal.circle") {
            if model.isConnected {
                connectedView
            } else {
                formView
            }
        }
    }

    private var connectedView: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MOBILE DATA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(Theme.secondary)
                    Text(model.telemetry.operatorName.isEmpty ? "Connected" : model.telemetry.operatorName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                }
                Spacer()
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 9, height: 9)
                    .shadow(color: Theme.accent.opacity(0.9), radius: 5)
            }

            HStack(spacing: 0) {
                SummaryCell(title: "IP ADDRESS", value: model.ipAddress ?? "—")
                Divider().overlay(Theme.stroke).frame(height: 30)
                SummaryCell(title: "UPTIME", value: model.uptimeText)
                Divider().overlay(Theme.stroke).frame(height: 30)
                SummaryCell(title: "DATA", value: "\(formatBytes(model.bytesIn)) ↓")
            }

            Button {
                model.disconnect()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                    Text(model.link == .disconnecting ? "Disconnecting…" : "Disconnect")
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.danger.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.danger.opacity(0.40), lineWidth: 1)
                )
                .foregroundColor(Theme.danger)
            }
            .buttonStyle(.plain)
            .disabled(model.busy)

            Text("Traffic is routed through the E1550 while connected.")
                .font(.system(size: 10))
                .foregroundColor(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldBox(title: "Access Point Name (APN)", placeholder: "e.g. internet", text: $model.apn)
                .onSubmit { model.connect() }

            HStack(spacing: 10) {
                FieldBox(title: "Dial number", placeholder: "*99#", text: $model.phone)
                FieldBox(title: "Username (optional)", placeholder: "usually empty", text: $model.username)
            }

            DisclosureGroup(isExpanded: $model.advancedExpanded) {
                FieldBox(title: "Password", placeholder: "usually empty", text: $model.password, secure: true)
                    .padding(.top, 4)
            } label: {
                Text("Advanced")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.secondary)
            }
            .tint(Theme.secondary)

            Button {
                model.toggleConnection()
            } label: {
                HStack(spacing: 8) {
                    if model.link == .connecting {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(model.link == .connecting ? "Connecting…" : "Connect")
                }
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .foregroundColor(Color(red: 0.03, green: 0.10, blue: 0.09))
            }
            .buttonStyle(.plain)
            .disabled(model.busy || !model.canConnect)
            .opacity(model.canConnect || model.link == .connecting ? 1 : 0.55)

            callout
        }
    }

    @ViewBuilder
    private var callout: some View {
        if let error = model.lastError {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.danger)
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try Again") { model.retry() }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.danger)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.danger.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.danger.opacity(0.22), lineWidth: 1))
        } else if model.link == .noModem || model.link == .driverInactive {
            hardwareCallout
        }
    }

    @ViewBuilder
    private var hardwareCallout: some View {
        let installerMode = model.usbDevices.contains(where: { $0.isInstallerMode })

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.warning)
                Text(hardwareHeadline(installerMode: installerMode))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Theme.text.opacity(0.90))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(hardwareHint(installerMode: installerMode))
                .font(.system(size: 10))
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if installerMode {
                Button("Switch to Modem Mode") { model.activateModem() }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.warning)
                    .disabled(model.busy)
            } else if !model.driverLoaded {
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.warning)
            } else {
                Button("Check Again") { model.retry() }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.warning)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.warning.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.warning.opacity(0.22), lineWidth: 1))
    }

    private func hardwareHeadline(installerMode: Bool) -> String {
        if model.usbDevices.isEmpty { return "Modem not connected" }
        if installerMode { return "Modem is in CD-ROM mode" }
        if !model.driverLoaded { return "Driver not loaded" }
        return "No serial port"
    }

    private func hardwareHint(installerMode: Bool) -> String {
        if model.usbDevices.isEmpty {
            return "Plug the E1550 into a USB port with a data cable."
        }
        if installerMode {
            return "The modem is showing its installer disc. Switch it to modem mode, then wait a few seconds."
        }
        if !model.driverLoaded {
            return "The Huawei driver is installed but macOS has not loaded it. Reboot, then reopen Mobile Partner."
        }
        return "The modem is in modem mode but the driver did not publish a serial port. Unplug and reconnect it, or copy diagnostics."
    }
}

struct FieldBox: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.tertiary)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SummaryCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundColor(Theme.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

// MARK: - Network

struct NetworkCard: View {
    @ObservedObject var model: ModemModel

    private var registrationColor: Color {
        if model.telemetry.isRegistered { return Theme.accent }
        if model.telemetry.registration == "Searching" { return Theme.warning }
        return Theme.secondary
    }

    private var simColor: Color {
        model.telemetry.simReady ? Theme.accent : Theme.warning
    }

    var body: some View {
        Card(title: "Network", icon: "globe") {
            VStack(spacing: 9) {
                InfoRow(
                    label: "Operator",
                    value: model.telemetry.operatorName.isEmpty ? "—" : model.telemetry.operatorName
                )
                InfoRow(
                    label: "Registration",
                    value: model.telemetry.registration,
                    valueColor: registrationColor
                )
                InfoRow(
                    label: "Packet data",
                    value: model.telemetry.packetAttached ? "Attached" : "Not attached",
                    valueColor: model.telemetry.packetAttached ? Theme.accent : Theme.secondary
                )
                InfoRow(
                    label: "SIM",
                    value: model.telemetry.sim,
                    valueColor: simColor
                )
                if !model.telemetry.modemAPN.isEmpty {
                    InfoRow(label: "Modem APN", value: model.telemetry.modemAPN)
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(Theme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Signal

struct SignalCard: View {
    @ObservedObject var model: ModemModel

    private var bars: Int { model.telemetry.signalBars }
    private var dbm: String {
        if let value = model.telemetry.signalDBm { return "\(value)" }
        return "—"
    }
    private var color: Color {
        switch bars {
        case 4...5: return Theme.accent
        case 2...3: return Theme.warning
        case 1: return Theme.danger
        default: return Theme.secondary
        }
    }

    var body: some View {
        Card(title: "Signal", icon: "cellularbars") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 7) {
                    Text(dbm)
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .foregroundColor(Theme.text)
                        .contentTransition(.numericText())
                    Text("dBm")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.tertiary)
                        .padding(.bottom, 7)
                    Spacer()
                    SignalBars(bars: bars, color: color)
                        .padding(.bottom, 5)
                }

                HStack {
                    Text(model.telemetry.signalQuality)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                    Spacer()
                    Text("AT+CSQ \(model.telemetry.signalRaw)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.tertiary)
                }

                Text(signalHint)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signalHint: String {
        if model.telemetry.signalRaw == 99 {
            return "No signal reported. Move to an area with coverage."
        }
        if model.telemetry.signalRaw == 0 {
            return "Signal is extremely weak."
        }
        if bars >= 4 { return "Strong signal — good conditions for a data connection." }
        if bars >= 2 { return "Usable signal. The connection may slow down indoors." }
        return "Weak signal. Try moving near a window."
    }
}

struct SignalBars: View {
    let bars: Int
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3.5) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                    .fill(index < bars ? color : Color.white.opacity(0.08))
                    .frame(width: 6, height: CGFloat(9 + index * 6))
            }
        }
    }
}

// MARK: - Device

struct DeviceCard: View {
    @ObservedObject var model: ModemModel

    var body: some View {
        Card(title: "Device", icon: "antenna.radiowaves.left.and.right") {
            VStack(spacing: 9) {
                InfoRow(
                    label: "Model",
                    value: model.telemetry.model.isEmpty ? "—" : model.telemetry.model
                )
                InfoRow(
                    label: "Firmware",
                    value: model.telemetry.firmware.isEmpty ? "—" : model.telemetry.firmware
                )
                InfoRow(
                    label: "IMEI",
                    value: model.telemetry.imei.isEmpty ? "—" : model.telemetry.imei
                )
                InfoRow(
                    label: "Ports",
                    value: model.portSummary
                )

                Divider().overlay(Theme.stroke).padding(.vertical, 1)

                HStack(spacing: 10) {
                    MiniBadge(ok: model.driverLoaded, label: "Driver")
                    MiniBadge(ok: model.helperOnline, label: "Helper")
                    Spacer()
                    Text("v1.0")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.tertiary)
                }
            }
        }
    }
}

struct MiniBadge: View {
    let ok: Bool
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? Theme.accent : Theme.tertiary)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(ok ? Theme.secondary : Theme.tertiary)
        }
    }
}

// MARK: - Log

struct LogView: View {
    @ObservedObject var model: ModemModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text("ACTIVITY")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.25)
                    .foregroundColor(Theme.secondary)
                if model.log.count > 0 {
                    Text("\(model.log.count)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                Spacer()
                Button(model.logExpanded ? "Hide" : "Show") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.logExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(Theme.secondary)

                Button("Clear") { model.clearLog() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(Theme.tertiary)
                    .disabled(model.log.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if model.logExpanded {
                Divider().overlay(Theme.stroke)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.log.suffix(250))) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.date, style: .time)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(Theme.tertiary)
                                        .frame(width: 58, alignment: .leading)
                                    Text(entry.text)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(color(for: entry.level))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                    .onChange(of: model.log.count) { _ in
                        if let last = model.log.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return Theme.text.opacity(0.80)
        case .success: return Theme.accent
        case .error: return Theme.danger
        case .detail: return Theme.secondary
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var model: ModemModel

    var body: some View {
        HStack(spacing: 13) {
            MiniBadge(ok: model.driverLoaded, label: "Kernel driver")
            MiniBadge(ok: model.helperOnline, label: "Helper")

            Spacer()

            Toggle("Auto-connect", isOn: $model.autoConnect)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10))
                .foregroundColor(Theme.secondary)
                .help("Connect automatically when the SIM is ready and an APN is set")

            Button {
                model.copyDiagnostics()
            } label: {
                Label("Diagnostics", systemImage: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy a report to the clipboard")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }
}

// MARK: - Quick help

struct QuickHelpCard: View {
    @ObservedObject var model: ModemModel

    var body: some View {
        Card(title: "Quick help", icon: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 8) {
                HelpStep(number: "1", text: "Insert a SIM with an active data plan.")
                HelpStep(number: "2", text: "Enter the APN supplied by your carrier.")
                HelpStep(number: "3", text: "Press Connect. macOS handles PPP and DNS.")
                Text("The dial number is *99# for almost every Huawei modem.")
                    .font(.system(size: 9.5))
                    .foregroundColor(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}

struct HelpStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(Theme.accent)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
                .overlay(Circle().stroke(Theme.accent.opacity(0.22), lineWidth: 1))
            Text(text)
                .font(.system(size: 10.5))
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Helpers

func formatBytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: value)
}
