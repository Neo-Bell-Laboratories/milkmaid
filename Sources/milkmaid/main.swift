import AppKit
import Foundation

private enum PowerSourceProfile: Equatable {
    case battery
    case charger

    var pmsetFlag: String {
        switch self {
        case .battery: return "-b"
        case .charger: return "-c"
        }
    }
}

private enum EnergyMode: String, CaseIterable, Equatable {
    case balanced
    case performance
    case batterySaver

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        case .batterySaver: return "Battery Saver"
        }
    }
}

private struct EnergySettings {
    let mode: EnergyMode
    let supportsPerformance: Bool
    let usesUnifiedMode: Bool
    let supportsHighPower: Bool
}

private struct BatteryReading {
    let percentage: Int?
    let charging: Bool
    let estimatedRemaining: String?
    let powerSource: PowerSourceProfile?

    var menuText: String {
        guard let percentage else { return "No built-in battery detected" }
        return "Battery: \(percentage)% · \(charging ? "Charging" : "Discharging")"
    }

    var estimateText: String {
        guard percentage != nil else { return "Battery estimate unavailable" }
        guard let estimatedRemaining else { return charging ? "Time until full: calculating…" : "Estimated battery life: calculating…" }
        return charging ? "Time until full: \(estimatedRemaining)" : "Estimated battery life: \(estimatedRemaining)"
    }
}

final class MilkmaidAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var batteryTimer: Timer?
    private var animationTimer: Timer?
    private var reading = BatteryReading(percentage: nil, charging: false, estimatedRemaining: nil, powerSource: nil)
    private var energySettings = EnergySettings(mode: .balanced, supportsPerformance: false, usesUnifiedMode: false, supportsHighPower: false)
    private var animationPhase = 0.0
    private var isApplyingEnergyMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        refreshBattery()
        refreshStatusItem()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animationPhase += 0.18
            self.refreshIcon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        batteryTimer?.invalidate()
        animationTimer?.invalidate()
    }

    @objc private func refreshNow() {
        refreshBattery()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshBattery() {
        reading = readBattery()
        refreshEnergySettings()
        refreshStatusItem()
    }

    private func readBattery() -> BatteryReading {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  let match = text.range(of: "([0-9]{1,3})%", options: .regularExpression),
                  let percent = Int(text[match].dropLast()) else {
                return BatteryReading(percentage: nil, charging: false, estimatedRemaining: nil, powerSource: nil)
            }

            let lines = text.split(whereSeparator: \.isNewline)
            let sourceLine = lines.first?.lowercased() ?? ""
            let batteryLine = lines.first(where: { $0.contains("%") })?.lowercased() ?? ""
            let powerSource: PowerSourceProfile? = sourceLine.contains("ac power") ? .charger : (sourceLine.contains("battery power") ? .battery : nil)
            let charging = batteryLine.contains("; charging") || batteryLine.contains("; charged")
            let timeRange = batteryLine.range(of: "([0-9]+):([0-9]{2}) remaining", options: .regularExpression)
            let estimatedRemaining = timeRange.map { time in
                String(batteryLine[time]).replacingOccurrences(of: " remaining", with: "")
            }
            return BatteryReading(
                percentage: min(100, max(0, percent)),
                charging: charging,
                estimatedRemaining: estimatedRemaining,
                powerSource: powerSource
            )
        } catch {
            return BatteryReading(percentage: nil, charging: false, estimatedRemaining: nil, powerSource: nil)
        }
    }


    @objc private func selectEnergyMode(_ sender: NSMenuItem) {
        guard !isApplyingEnergyMode,
              let rawValue = sender.representedObject as? String,
              let mode = EnergyMode(rawValue: rawValue),
              mode != .performance || energySettings.supportsPerformance,
              let command = powerModeCommand(for: mode) else { return }

        isApplyingEnergyMode = true
        refreshStatusItem()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = runAuthorizedPowerCommand(command)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isApplyingEnergyMode = false
                self.refreshEnergySettings()
                self.refreshStatusItem()
                if let error {
                    self.showEnergyModeError(error)
                } else if self.energySettings.mode != mode {
                    self.showEnergyModeError("macOS did not confirm the selected mode. This mode may not be supported for the current power source.")
                }
            }
        }
    }

    private func refreshEnergySettings() {
        let capabilities = runPMSet(["-g", "cap"])
        let custom = runPMSet(["-g", "custom"])
        let usesUnifiedMode = settingValue("powermode", in: custom) != nil || hasCapability("powermode", in: capabilities)
        let supportsHighPower = hasCapability("highpowermode", in: capabilities) || settingValue("highpowermode", in: custom) != nil
        let unifiedValue = settingValue("powermode", in: custom)
        let highValue = settingValue("highpowermode", in: custom)
        let lowValue = settingValue("lowpowermode", in: custom)

        let mode: EnergyMode
        if let unifiedValue, unifiedValue == "2" {
            mode = .performance
        } else if highValue == "1" {
            mode = .performance
        } else if (unifiedValue == "1") || (lowValue == "1") {
            mode = .batterySaver
        } else {
            mode = .balanced
        }
        energySettings = EnergySettings(
            mode: mode,
            supportsPerformance: usesUnifiedMode || supportsHighPower,
            usesUnifiedMode: usesUnifiedMode,
            supportsHighPower: supportsHighPower
        )
    }

    private func settingValue(_ key: String, in output: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(pattern: "(?m)^\\s*\(escapedKey)\\s+([0-9]+)\\b"),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let valueRange = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[valueRange])
    }

    private func hasCapability(_ key: String, in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == key }
    }

    private func runPMSet(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func powerModeCommand(for mode: EnergyMode) -> String? {
        let sourceFlag = reading.powerSource?.pmsetFlag ?? "-a"
        if energySettings.usesUnifiedMode {
            let value: Int
            switch mode {
            case .balanced: value = 0
            case .batterySaver: value = 1
            case .performance: value = 2
            }
            return "/usr/bin/pmset \(sourceFlag) powermode \(value)"
        }

        if mode == .performance && !energySettings.supportsHighPower { return nil }
        var arguments = [sourceFlag]
        if energySettings.supportsHighPower {
            arguments += ["highpowermode", mode == .performance ? "1" : "0"]
        }
        arguments += ["lowpowermode", mode == .batterySaver ? "1" : "0"]
        return "/usr/bin/pmset " + arguments.joined(separator: " ")
    }

    private func showEnergyModeError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Energy mode wasn’t changed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func refreshStatusItem() {
        refreshIcon()
        let menu = NSMenu()
        let status = NSMenuItem(title: reading.menuText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let estimate = NSMenuItem(title: reading.estimateText, action: nil, keyEquivalent: "")
        estimate.isEnabled = false
        menu.addItem(estimate)
        menu.addItem(.separator())

        let modeTitle = reading.powerSource == .battery ? "Energy Mode (Battery)" : "Energy Mode (Power Adapter)"
        let modeItem = NSMenuItem(title: modeTitle, action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in EnergyMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectEnergyMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = energySettings.mode == mode ? .on : .off
            item.isEnabled = !isApplyingEnergyMode && (mode != .performance || energySettings.supportsPerformance)
            modeMenu.addItem(item)
        }
        if !energySettings.supportsPerformance {
            let unsupported = NSMenuItem(title: "Performance unavailable on this Mac", action: nil, keyEquivalent: "")
            unsupported.isEnabled = false
            modeMenu.addItem(.separator())
            modeMenu.addItem(unsupported)
        }
        modeMenu.addItem(.separator())
        let currentMode = NSMenuItem(title: isApplyingEnergyMode ? "Changing energy mode…" : "Current: \(energySettings.mode.title)", action: nil, keyEquivalent: "")
        currentMode.isEnabled = false
        modeMenu.addItem(currentMode)
        menu.setSubmenu(modeMenu, for: modeItem)
        menu.addItem(modeItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Battery Status", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit milkmaid", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refreshIcon() {
        guard statusItem != nil else { return }
        statusItem.button?.image = makeIcon()
        statusItem.button?.image?.isTemplate = false
        statusItem.button?.toolTip = "milkmaid · \(reading.menuText)"
    }

    private func makeIcon() -> NSImage {
        let size = NSSize(width: 26, height: 24)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let outline = dark ? NSColor.white : NSColor.black
        let milk = NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.81, alpha: 1)
        let percent = CGFloat(reading.percentage ?? 0)
        let levelY = 4.4 + (10.5 * percent / 100)
        let ripple = CGFloat(sin(animationPhase) * 0.42)

        let image = NSImage(size: size, flipped: false) { _ in
            let interior = NSBezierPath()
            interior.move(to: NSPoint(x: 5.5, y: 14.5))
            interior.line(to: NSPoint(x: 6.8, y: 7.8))
            interior.curve(to: NSPoint(x: 18.8, y: 7.8), controlPoint1: NSPoint(x: 9.2, y: 6.6), controlPoint2: NSPoint(x: 16.2, y: 6.6))
            interior.line(to: NSPoint(x: 20.2, y: 14.5))
            interior.curve(to: NSPoint(x: 17.8, y: 17.7), controlPoint1: NSPoint(x: 20.2, y: 16.2), controlPoint2: NSPoint(x: 19.3, y: 17.5))
            interior.line(to: NSPoint(x: 8, y: 17.7))
            interior.curve(to: NSPoint(x: 5.5, y: 14.5), controlPoint1: NSPoint(x: 6.2, y: 17.5), controlPoint2: NSPoint(x: 5.5, y: 16.3))
            interior.close()

            if percent > 0 {
                NSGraphicsContext.saveGraphicsState()
                interior.addClip()
                let liquid = NSBezierPath()
                liquid.move(to: NSPoint(x: 4, y: levelY + ripple))
                liquid.curve(to: NSPoint(x: 22, y: levelY - ripple), controlPoint1: NSPoint(x: 9, y: levelY + 0.55 - ripple), controlPoint2: NSPoint(x: 16, y: levelY - 0.55 + ripple))
                liquid.line(to: NSPoint(x: 22, y: 3))
                liquid.line(to: NSPoint(x: 4, y: 3))
                liquid.close()
                milk.setFill()
                liquid.fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            let bowl = NSBezierPath()
            bowl.lineWidth = 1.7
            bowl.lineJoinStyle = .round
            bowl.move(to: NSPoint(x: 3.1, y: 15.7))
            bowl.line(to: NSPoint(x: 5.5, y: 20.5))
            bowl.line(to: NSPoint(x: 9, y: 17.2))
            bowl.curve(to: NSPoint(x: 17, y: 17.2), controlPoint1: NSPoint(x: 11.1, y: 16.5), controlPoint2: NSPoint(x: 14.9, y: 16.5))
            bowl.line(to: NSPoint(x: 20.5, y: 20.5))
            bowl.line(to: NSPoint(x: 22.9, y: 15.7))
            bowl.curve(to: NSPoint(x: 18.7, y: 6), controlPoint1: NSPoint(x: 22.9, y: 11.5), controlPoint2: NSPoint(x: 20.8, y: 7.2))
            bowl.curve(to: NSPoint(x: 7.3, y: 6), controlPoint1: NSPoint(x: 15.8, y: 4.7), controlPoint2: NSPoint(x: 10.2, y: 4.7))
            bowl.curve(to: NSPoint(x: 3.1, y: 15.7), controlPoint1: NSPoint(x: 5.2, y: 7.2), controlPoint2: NSPoint(x: 3.1, y: 11.5))
            bowl.close()
            outline.setStroke()
            bowl.stroke()

            // A small curved lip makes the cat-shaped bowl read as a vessel.
            let lip = NSBezierPath()
            lip.lineWidth = 1.35
            lip.move(to: NSPoint(x: 4.1, y: 15.6))
            lip.curve(to: NSPoint(x: 21.9, y: 15.6), controlPoint1: NSPoint(x: 9, y: 14.8), controlPoint2: NSPoint(x: 17, y: 14.8))
            outline.setStroke()
            lip.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private func runAuthorizedPowerCommand(_ shellCommand: String) -> String? {
    let script = "do shell script \"\(shellCommand)\" with administrator privileges"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let output = Pipe()
    let errorOutput = Pipe()
    process.standardOutput = output
    process.standardError = errorOutput
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (message?.isEmpty == false ? message : "Authorization was canceled or macOS rejected the change.")
        }
        _ = data
        return nil
    } catch {
        return error.localizedDescription
    }
}

@main
enum MilkmaidMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = MilkmaidAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
