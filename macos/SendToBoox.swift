import AppKit
import UniformTypeIdentifiers

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct Connection: Codable {
    let endpoint: String
    let identity: String
}

// Invoke tools with argument arrays; no local shell evaluates filenames or URLs.
final class Boox {
    let adb: String
    let settings: URL
    private let processLock = NSLock()
    private var activeProcess: Process?
    func stop() {
        processLock.lock()
        defer { processLock.unlock() }
        if let process = activeProcess, process.isRunning { process.terminate() }
    }
    init(adbPath: String? = nil, settingsURL: URL? = nil) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = (adbPath.map { [$0] } ?? []) + ["/opt/local/bin/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                     home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppError(message: "ADB was not found. Install Android platform-tools using MacPorts or Homebrew, then reopen this app.\n\nThe app checks /opt/local/bin, /opt/homebrew/bin, /usr/local/bin, your Android SDK, and PATH.")
        }
        adb = path
        settings = settingsURL ?? home.appendingPathComponent("Library/Application Support/Send to BOOX/wireless.json")
    }
    func run(_ arguments: [String], input: String? = nil, seconds: Double = 15) throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let pipe = Pipe()
        process.standardInput = pipe
        processLock.lock()
        do { try process.run(); activeProcess = process }
        catch { processLock.unlock(); throw error }
        processLock.unlock()
        defer {
            processLock.lock()
            activeProcess = nil
            processLock.unlock()
        }
        if let input = input { pipe.fileHandleForWriting.write(Data(input.utf8)) }
        try? pipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw AppError(message: "ADB timed out. Wake BOOX, check its connection, and try again.")
        }
        process.waitUntilExit()
        let text = String(decoding: try Data(contentsOf: temporary), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw AppError(message: text) }
        return text
    }
    func identity(_ serial: String) throws -> String {
        let value = try run(["-s", serial, "shell", "getprop", "ro.serialno"])
        guard !value.isEmpty && !value.contains("\n") else { throw AppError(message: "Cannot verify BOOX's serial number.") }
        return value
    }
    func usb() throws -> String {
        guard try run(["-d", "get-state"]) == "device" else { throw AppError(message: "USB is not ready.") }
        return try run(["-d", "get-serialno"])
    }
    func connect(_ endpoint: String) throws -> String {
        guard Self.validEndpoint(endpoint) else { throw AppError(message: "Enter an IPv4 address and port, for example 192.168.1.20:5555.") }
        _ = try run(["connect", endpoint])
        guard try run(["-s", endpoint, "get-state"]) == "device" else { throw AppError(message: "BOOX is not connected. Check its address and debugging authorization.") }
        return try identity(endpoint)
    }
    static func validEndpoint(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let port = Int(pieces[1]), (1...65535).contains(port) else { return false }
        let octets = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } && Int(part).map { (0...255).contains($0) } == true
        } && pieces[1].allSatisfy { $0.isASCII && $0.isNumber }
    }
    func save(_ connection: Connection) throws {
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(connection).write(to: settings, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
    }
    func saved() -> Connection? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: data)
    }
    func restore(_ connection: Connection) throws -> String {
        var candidates = [connection.endpoint]
        if let services = try? run(["mdns", "services"]) {
            for line in services.components(separatedBy: .newlines) {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                if fields.count >= 3 && fields[1].hasPrefix("_adb-tls-connect._tcp"),
                   let last = fields.last, Self.validEndpoint(String(last)) {
                    candidates.append(String(last))
                }
            }
        }
        var seen = Set<String>()
        for endpoint in candidates where seen.insert(endpoint).inserted {
            if let actual = try? connect(endpoint), actual == connection.identity {
                try save(Connection(endpoint: endpoint, identity: actual))
                return endpoint
            }
        }
        throw AppError(message: "Your remembered BOOX was not found. Wake it and enable Wireless debugging. If its address changed, run Wi-Fi setup again. USB-based Wi-Fi setup may need repeating after a BOOX restart.")
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func send(_ items: [URL], serial: String) throws {
        // Validate the whole batch before copying any files.
        for item in items {
            if item.isFileURL {
                guard item.pathExtension.lowercased() == "pdf", FileManager.default.isReadableFile(atPath: item.path),
                      let handle = try? FileHandle(forReadingFrom: item) else { throw AppError(message: "Select a readable PDF: \(item.path)") }
                let prefix = handle.readData(ofLength: 1024)
                try? handle.close()
                guard prefix.range(of: Data("%PDF-".utf8)) != nil else { throw AppError(message: "This is not a PDF: \(item.path)") }
            } else {
                guard ["http", "https"].contains(item.scheme?.lowercased() ?? ""), item.host?.isEmpty == false else { throw AppError(message: "Enter an http:// or https:// webpage URL.") }
            }
        }
        for item in items {
            var target = item.absoluteString
            if item.isFileURL {
                _ = try run(["-s", serial, "shell", "mkdir -p /sdcard/Books"])
                let destination = "/sdcard/Books/" + item.lastPathComponent
                _ = try run(["-s", serial, "push", item.path, destination], seconds: 300)
                target = URL(fileURLWithPath: destination).absoluteString
            }
            let command = "am start -W -a android.intent.action.VIEW -d " + Self.shellQuote(target) + (item.isFileURL ? " -t application/pdf" : "")
            let output = try run(["-s", serial, "shell", command], seconds: 30)
            if ["Error", "Exception", "unable to resolve"].contains(where: output.contains) {
                throw AppError(message: "BOOX could not open \(item.lastPathComponent). A copied PDF remains in /sdcard/Books.\n\n\(output)")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var queued: [URL] = []
    var started = false
    var activeBoox: Boox?
    @objc func quit(_ sender: Any?) { NSApp.terminate(sender) }
    func applicationWillTerminate(_ notification: Notification) { activeBoox?.stop() }
    func application(_ application: NSApplication, open urls: [URL]) {
        queued.append(contentsOf: urls)
        if started { return }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Send to BOOX", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true)
        // Finder's initial document event can arrive after launch notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.start() }
    }
    func dialog(_ text: String, buttons: [String] = ["OK"]) -> Int {
        let alert = NSAlert()
        alert.messageText = "Send to BOOX"
        alert.informativeText = text
        buttons.forEach {
            let button = alert.addButton(withTitle: $0)
            if $0 == "Cancel" { button.keyEquivalent = "\u{1b}" }
        }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
    func entry(_ text: String, value: String = "", secret: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = "Send to BOOX"
        alert.informativeText = text
        let field: NSTextField = secret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Run ADB off the UI thread while a native progress window remains responsive.
    func work<T>(_ label: String, _ operation: @escaping () throws -> T) throws -> T {
        let alert = NSAlert()
        alert.messageText = label
        alert.informativeText = "Keep BOOX awake. This window closes when the operation finishes."
        let quitButton = alert.addButton(withTitle: "Quit")
        quitButton.target = self
        quitButton.action = #selector(quit(_:))
        quitButton.keyEquivalent = "q"
        quitButton.keyEquivalentModifierMask = [.command]
        var result: Result<T, Error>!
        DispatchQueue.global().async {
            let outcome = Result { try operation() }
            DispatchQueue.main.async { result = outcome; NSApp.stopModal() }
        }
        alert.runModal()
        alert.window.orderOut(nil)
        return try result.get()
    }
    func wifi(_ boox: Boox) throws -> Bool {
        let mode = dialog("Connect your Mac and BOOX to the same trusted home network. Continue only on a network you trust.\n\nUSB setup requires a data cable, USB Debug Mode enabled, and authorization accepted on BOOX.", buttons: ["USB setup", "Wireless pairing", "Existing address", "Cancel"])
        if mode == 3 { return false }
        var expected: String?
        var suggested = ""
        if mode == 0 {
            let values: (String, String) = try work("Enabling Wi-Fi access…") {
                let usb = try boox.usb()
                let identity = try boox.identity(usb)
                let address = (try? boox.run(["-s", usb, "shell", "ip", "-o", "-4", "addr", "show", "wlan0"])) ?? ""
                _ = try boox.run(["-s", usb, "tcpip", "5555"])
                return (identity, address)
            }
            expected = values.0
            let words = values.1.split(whereSeparator: { $0.isWhitespace })
            if let index = words.firstIndex(of: "inet"), index + 1 < words.count {
                suggested = String(words[index + 1].split(separator: "/")[0]) + ":5555"
            }
        } else if mode == 1 {
            guard let address = entry("On BOOX: Developer options → Wireless debugging → Pair device with pairing code. Enter the IP address and PAIRING port shown there."), Boox.validEndpoint(address) else { return false }
            guard let code = entry("Enter the six-digit pairing code.", secret: true) else { return false }
            guard code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw AppError(message: "The pairing code must have six digits.") }
            let output = try work("Pairing with BOOX…") { try boox.run(["pair", address], input: code + "\n", seconds: 30) }
            guard output.contains("Successfully paired") else { throw AppError(message: output) }
            suggested = String(address.split(separator: ":")[0]) + ":"
        }
        guard let endpoint = entry("Enter BOOX's IPv4 address and CONNECTION port. For Wireless debugging, use its main screen, not the pairing window. For USB setup, use port 5555. Keep USB connected until verification finishes.", value: suggested) else { return false }
        try work("Connecting and verifying BOOX…") {
            let actual = try boox.connect(endpoint)
            if let expected = expected, actual != expected { throw AppError(message: "This address belongs to a different device from the BOOX connected by USB. Settings were not saved.") }
            try boox.save(Connection(endpoint: endpoint, identity: actual))
        }
        _ = dialog("Wi-Fi is ready. You can unplug USB.\n\nAfter a BOOX restart, enable Wireless debugging again or repeat USB setup. Pairing is remembered, but connection ports can change.")
        return true
    }
    func connection(_ boox: Boox) throws -> String? {
        while true {
            if let usb = try? work("Checking USB…", { try boox.usb() }) { return usb }
            if let saved = boox.saved() {
                let answer = dialog("USB is unavailable. Are your Mac and BOOX on the same trusted home network?", buttons: ["Connect over Wi-Fi", "Connection setup", "Cancel"])
                if answer == 2 { return nil }
                if answer == 1 { _ = try wifi(boox); continue }
                do { return try work("Finding your remembered BOOX…") { try boox.restore(saved) } }
                catch { _ = dialog(error.localizedDescription) }
            }
            let choice = dialog("Connect only your BOOX by USB, enable USB Debug Mode, unlock it, and accept the authorization prompt.\n\nYour selected files will wait while you reconnect.", buttons: ["Retry USB", "Set up Wi-Fi", "Cancel"])
            if choice == 2 { return nil }
            if choice == 1 { _ = try wifi(boox) }
        }
    }
    func start() {
        started = true
        defer { NSApp.terminate(nil) }
        do {
            let boox = try Boox()
            activeBoox = boox
            var items = queued
            if items.isEmpty {
                let action = dialog("What would you like to do?", buttons: ["Send PDFs", "Send webpage", "Set up Wi-Fi", "Cancel"])
                switch action {
                case 0:
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.allowsMultipleSelection = true
                    guard panel.runModal() == .OK else { return }
                    items = panel.urls
                case 1:
                    guard let text = entry("Paste a webpage URL (https:// or http://):"), let url = URL(string: text) else { return }
                    items = [url]
                case 2: _ = try wifi(boox); return
                default: return
                }
            }
            guard let serial = try connection(boox) else { return }
            try work("Sending to BOOX…") { try boox.send(items, serial: serial) }
            _ = dialog("Sent and opened \(items.count) item(s) on BOOX.")
        } catch { _ = dialog(error.localizedDescription) }
    }
}

#if !TESTING
@main
enum SendToBooxApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
#endif
