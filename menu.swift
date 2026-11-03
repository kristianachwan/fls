// FLS menu bar app: shows app memory and controls the FLS watchdog.
//
// It kills nothing itself. The watchdog is the FLS command-line tool, run by launchd, so
// protection keeps working if this app quits or hangs under memory pressure. Its settings
// live in the watchdog's launchd plist, which is what this app reads back.

import AppKit

struct AppUsage {
    let name: String
    let gb: Double
}

struct Rule {
    var appGB: Double = 80
    var totalGB: Double = 0  // 0 means off
    var dryRun = false

    var arguments: [String] {
        ["--limit", format(appGB)] + (totalGB > 0 ? ["--total", format(totalGB)] : [])
    }
}

struct Snapshot {
    var totalGB = 0.0
    var apps: [AppUsage] = []
    var biggestProcess: AppUsage?
    var isOn = false
    var rule = Rule()
}

let refreshSeconds = 10.0
let startPositionFromRight = 320.0
let warningRatio = 0.9
let visibleApps = 8
let appLimitChoices = [40.0, 60, 80]
let totalLimitChoices = [60.0, 70, 80, 90]

let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.fls.monitor.plist"
let logPath = NSHomeDirectory() + "/Library/Logs/FLS.log"
let watchdogService = "gui/\(getuid())/com.fls.monitor"

func format(_ gb: Double) -> String {
    String(format: "%g", gb)
}

@discardableResult
func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Parses `FLS --list` rows such as " 33.03 GB     93  Google Chrome.app".
func parseList(_ text: String) -> (totalGB: Double, apps: [AppUsage], biggestProcess: AppUsage?) {
    let biggestPrefix = "biggest process: "
    var totalGB = 0.0
    var apps: [AppUsage] = []
    var biggestProcess: AppUsage?
    for line in text.split(separator: "\n").dropFirst() {
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count == 4, let gb = Double(parts[0]) else { continue }
        let name = parts[3].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("total, ") {
            totalGB = gb
        } else if name.hasPrefix(biggestPrefix) {
            biggestProcess = AppUsage(name: String(name.dropFirst(biggestPrefix.count)), gb: gb)
        } else {
            apps.append(AppUsage(name: name.replacingOccurrences(of: ".app", with: ""), gb: gb))
        }
    }
    return (totalGB, apps, biggestProcess)
}

func installedRule() -> Rule? {
    guard let plist = NSDictionary(contentsOfFile: plistPath),
        let arguments = plist["ProgramArguments"] as? [String]
    else { return nil }
    func value(_ flag: String) -> Double? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return Double(arguments[index + 1])
    }
    return Rule(
        appGB: value("--limit") ?? 80,
        totalGB: value("--total") ?? 0,
        dryRun: arguments.contains("--dry-run"))
}

/// Shortens "2026-11-03 18:40:00 Killed Chrome (45.2 GB, 71 processes): why" to
/// "11-03 18:40  Chrome (45.2 GB, 71 processes)". The full line stays in the log.
func lastKill() -> String? {
    guard let log = try? String(contentsOfFile: logPath, encoding: .utf8),
        let line = log.split(separator: "\n").last(where: { $0.contains(" Killed ") })
    else { return nil }
    let parts = line.components(separatedBy: " Killed ")
    let time = parts[0].dropFirst(5).dropLast(3)
    let target = parts[1].components(separatedBy: ": ")[0]
    return "\(time)  \(target)"
}

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem: NSStatusItem = {
        // macOS adds new icons on the far left, where a crowded menu bar hides them behind the
        // notch. Start nearer the clock. After that macOS remembers where the icon was dragged.
        let positionKey = "NSStatusItem Preferred Position FLS"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(startPositionFromRight, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "FLS"
        return item
    }()
    private let menu = NSMenu()
    private let resources = Bundle.main.resourcePath!
    private var snapshot = Snapshot()
    private var isRefreshing = false

    /// The rule used by "Turn On", remembered across turning protection off.
    private var savedRule: Rule {
        get {
            let defaults = UserDefaults.standard
            let appGB = defaults.double(forKey: "appGB")
            return Rule(appGB: appGB > 0 ? appGB : 80, totalGB: defaults.double(forKey: "totalGB"))
        }
        set {
            UserDefaults.standard.set(newValue.appGB, forKey: "appGB")
            UserDefaults.standard.set(newValue.totalGB, forKey: "totalGB")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.button?.title = "FLS"
        refresh()
        let timer = Timer(timeInterval: refreshSeconds, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let watchdog = resources + "/FLS"
        let fallback = savedRule
        DispatchQueue.global(qos: .utility).async {
            let list = parseList(run(watchdog, ["--list"]).output)
            let isOn = run("/bin/launchctl", ["print", watchdogService]).status == 0
            let next = Snapshot(
                totalGB: list.totalGB, apps: list.apps, biggestProcess: list.biggestProcess, isOn: isOn,
                rule: isOn ? (installedRule() ?? fallback) : fallback)
            DispatchQueue.main.async {
                self.snapshot = next
                self.isRefreshing = false
                self.updateTitle()
            }
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        // Kept short: every extra point can push another app's icon behind the notch.
        let title = snapshot.isOn ? "\(Int(snapshot.totalGB.rounded()))G" : "FLS"
        let rule = snapshot.rule
        let nearLimit =
            (rule.totalGB > 0 && snapshot.totalGB >= rule.totalGB * warningRatio)
            || (snapshot.apps.first?.gb ?? 0) >= rule.appGB * warningRatio
        let color: NSColor? = !snapshot.isOn ? .secondaryLabelColor : nearLimit ? .systemRed : nil
        if let color {
            button.attributedTitle = NSAttributedString(
                string: title, attributes: [.font: button.font as Any, .foregroundColor: color])
        } else {
            button.title = title
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let rule = snapshot.rule

        addInfo(snapshot.isOn ? "Protection: On\(rule.dryRun ? " (dry run, kills nothing)" : "")" : "Protection: Off", to: menu)
        addAction(snapshot.isOn ? "Turn Off" : "Turn On", #selector(toggleProtection))
        menu.addItem(.separator())

        addLimitMenu(
            "Kill a process or app over", choices: appLimitChoices, current: rule.appGB,
            includesOff: false, action: #selector(chooseAppLimit(_:)))
        addLimitMenu(
            "Kill the biggest app when all apps pass", choices: totalLimitChoices, current: rule.totalGB,
            includesOff: true, action: #selector(chooseTotalLimit(_:)))
        menu.addItem(.separator())

        addInfo(row(snapshot.totalGB, "All apps"), to: menu)
        for app in snapshot.apps.prefix(visibleApps) {
            addInfo(row(app.gb, app.name), to: menu)
        }
        if let process = snapshot.biggestProcess {
            addInfo(row(process.gb, "Biggest process: \(process.name)"), to: menu)
        }
        menu.addItem(.separator())

        if let kill = lastKill() {
            addInfo("Last kill: \(kill)", to: menu)
        }
        let openLog = addAction("Open Log", #selector(openLog))
        openLog.isEnabled = FileManager.default.fileExists(atPath: logPath)
        addAction("Hide Menu Bar Icon (protection keeps running)", #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    private func row(_ gb: Double, _ name: String) -> String {
        String(format: "%6.1f GB  %@", gb, name)
    }

    private func addInfo(_ title: String, to menu: NSMenu) {
        // Enabled with no action: a disabled item would grey out the numbers this menu exists to show.
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    private func addLimitMenu(
        _ title: String, choices: [Double], current: Double, includesOff: Bool, action: Selector
    ) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        var values = includesOff ? [0.0] : []
        values += Set(choices + (current > 0 ? [current] : [])).sorted()
        for value in values {
            let item = NSMenuItem(
                title: value == 0 ? "Off" : "\(format(value)) GB", action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = value == current ? .on : .off
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    // MARK: Actions

    @objc private func chooseAppLimit(_ sender: NSMenuItem) {
        guard let gb = sender.representedObject as? Double else { return }
        var rule = snapshot.rule
        rule.appGB = gb
        install(rule)
    }

    @objc private func chooseTotalLimit(_ sender: NSMenuItem) {
        guard let gb = sender.representedObject as? Double else { return }
        var rule = snapshot.rule
        rule.totalGB = gb
        install(rule)
    }

    @objc private func toggleProtection() {
        if snapshot.isOn {
            runScript("uninstall.sh", [])
        } else {
            install(savedRule)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    /// Choosing a limit also turns protection on, so a picked rule is always the one in force.
    private func install(_ rule: Rule) {
        savedRule = rule
        runScript("install.sh", rule.arguments)
    }

    private func runScript(_ name: String, _ arguments: [String]) {
        let script = resources + "/" + name
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run("/bin/sh", [script] + arguments)
            DispatchQueue.main.async {
                if result.status != 0 {
                    let alert = NSAlert()
                    alert.messageText = "FLS couldn't change protection"
                    alert.informativeText = result.output
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                self.refresh()
            }
        }
    }
}

let application = NSApplication.shared
let controller = Controller()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
