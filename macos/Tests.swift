import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let boox = try Boox(adbPath: directory.appendingPathComponent("adb").path,
                    settingsURL: directory.appendingPathComponent("settings/wireless.json"))
for address in ["192.168.1.2:5555", "10.0.0.1:65535"] { assert(Boox.validEndpoint(address)) }
for address in ["256.1.1.1:5555", "1.2.3.4:0", "1.2.3.4:65536", "host:5555", "1.2.3.4:5;echo"] { assert(!Boox.validEndpoint(address)) }
let previous = Connection(endpoint: "192.168.1.8:5555", identity: "BOOX123")
try boox.save(previous)
let restored = try boox.restore(previous)
assert(restored == "192.168.1.9:4567", "Reject wrong serial; rediscover the correct device")
assert(boox.saved()?.endpoint == restored)
let file = directory.appendingPathComponent("a 'quoted' #%.pdf")
try Data("%PDF-1.4\n".utf8).write(to: file)
try boox.send([file, URL(string: "https://example.org/a?q=one%27two")!], serial: restored)
let log = directory.appendingPathComponent("log")
let before = try Data(contentsOf: log)
let invalid = directory.appendingPathComponent("invalid.pdf")
try Data("not a pdf".utf8).write(to: invalid)
do {
    try boox.send([file, invalid], serial: restored)
    fatalError("Invalid batch should fail")
} catch {}
let after = try Data(contentsOf: log)
assert(after == before, "Validate all files before sending")
let commands = String(decoding: before, as: UTF8.self)
assert(commands.contains(file.path))
assert(commands.contains("%23%25.pdf"))
assert(Boox.shellQuote("a'b") == "'a'\\''b'")
let completed = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    defer { completed.signal() }
    _ = try? boox.run(["wait"])
}
// Wait for the mock to start, then exercise the same stop used when quitting.
let deadline = Date().addingTimeInterval(3)
while Date() < deadline {
    if (try? String(contentsOf: log, encoding: .utf8).hasSuffix("wait\n")) == true { break }
    Thread.sleep(forTimeInterval: 0.02)
}
boox.stop()
assert(completed.wait(timeout: .now() + 3) == .success, "Quit stops an active ADB operation promptly")
print("Passed: endpoint validation, identity verification, mDNS recovery, settings, PDF and URL transfer, batch validation, shell quoting")
