import Foundation
import Darwin

var failures = 0

func check(_ actual: AutoOffAction, _ expected: AutoOffAction, _ name: String) {
    if actual == expected {
        print("ok - \(name)")
    } else {
        failures += 1
        print("FAIL - \(name): got \(actual), expected \(expected)")
    }
}

// threshold 0 disables the feature entirely
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 5, onAC: false, threshold: 0),
      .none, "threshold 0 disables")

// suspend just below threshold, on battery
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 19, onAC: false, threshold: 20),
      .suspend, "suspend below threshold on battery")

// no suspend exactly at threshold (strict less-than)
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 20, onAC: false, threshold: 20),
      .none, "no suspend at exactly threshold")

// never suspend on AC
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 5, onAC: true, threshold: 20),
      .none, "no suspend on AC")

// never suspend when the user hasn't turned Awayke on
check(AutoOffPolicy.decide(intent: false, suspended: false, percent: 5, onAC: false, threshold: 20),
      .none, "no suspend when intent off")

// resume at threshold + hysteresis, on AC
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 25, onAC: true, threshold: 20),
      .resume, "resume at threshold+hysteresis on AC")

// no resume below hysteresis band
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 24, onAC: true, threshold: 20),
      .none, "no resume below hysteresis")

// resume requires AC even when charge is high
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 30, onAC: false, threshold: 20),
      .none, "no resume on battery")

// a manual override suppresses suspend for the rest of the discharge
check(AutoOffPolicy.decide(intent: true, suspended: false, overridden: true, percent: 5, onAC: false, threshold: 20),
      .none, "override suppresses suspend")

// the override does not block a later resume once back on AC
check(AutoOffPolicy.decide(intent: true, suspended: true, overridden: true, percent: 25, onAC: true, threshold: 20),
      .resume, "override does not block resume")

func checkBool(_ actual: Bool, _ expected: Bool, _ name: String) {
    if actual == expected {
        print("ok - \(name)")
    } else {
        failures += 1
        print("FAIL - \(name): got \(actual), expected \(expected)")
    }
}

// the override survives while still discharging
checkBool(AutoOffPolicy.shouldKeepOverride(true, onAC: false), true, "override survives on battery")

// reaching AC ends the override, re-arming auto-off for the next discharge
checkBool(AutoOffPolicy.shouldKeepOverride(true, onAC: true), false, "override ends on AC")

// nothing to keep when there was no override
checkBool(AutoOffPolicy.shouldKeepOverride(false, onAC: false), false, "no override stays no override")

// A lid session started while open waits for a close, then expires on open.
let openStart = LidSessionTracker()
openStart.start(lidClosed: false)
checkBool(openStart.isWaitingForClose, true, "open-start lid session waits for close")
checkBool(openStart.handle(lidClosed: false), false, "open state does not immediately expire")
checkBool(openStart.handle(lidClosed: true), false, "lid close arms session end")
checkBool(openStart.isWaitingForClose, false, "closed session now waits for open")
checkBool(openStart.handle(lidClosed: false), true, "lid reopen expires session")
checkBool(openStart.handle(lidClosed: false), false, "lid session expires only once")

// Starting while already closed (for example through an external display)
// should expire on the next open without requiring another close first.
let closedStart = LidSessionTracker()
closedStart.start(lidClosed: true)
checkBool(closedStart.handle(lidClosed: false), true, "closed-start session expires on open")

let cancelled = LidSessionTracker()
cancelled.start(lidClosed: false)
cancelled.cancel()
checkBool(cancelled.handle(lidClosed: true), false, "cancelled lid session ignores close")
checkBool(cancelled.handle(lidClosed: false), false, "cancelled lid session ignores open")

// If IOKit has not produced its initial reading yet, conservatively wait for
// a complete close/open cycle rather than treating the current state as closed.
let unknownStart = LidSessionTracker()
unknownStart.start(lidClosed: nil)
checkBool(unknownStart.isWaitingForClose, true, "unknown-start session waits for close")
checkBool(unknownStart.handle(lidClosed: true), false, "unknown-start close arms session end")
checkBool(unknownStart.handle(lidClosed: false), true, "unknown-start reopen expires session")

// Socket tests use a private directory and never invoke the privileged helper.
let testDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("s-\(UUID().uuidString.prefix(8))")
let socketPath = testDirectory.appendingPathComponent("control.sock").path
var active = false
var server: CommandServer? = try CommandServer(path: socketPath) { command, reply in
    if command == .on { active = true }
    if command == .off { active = false }
    reply(ControlReply(ok: true, status: ControlStatus(
        active: active, intent: active, suspendedForBattery: false, batteryOverride: false,
        batteryThreshold: 20, session: active ? "indefinite" : "none",
        remainingSeconds: nil, helper: "enabled", busy: false
    )))
}
do {
    _ = try CommandServer(path: socketPath) { _, reply in reply(ControlReply(ok: true)) }
    checkBool(false, true, "second server cannot replace a live control socket")
} catch {
    checkBool(true, true, "second server cannot replace a live control socket")
}
let socketPermissions = try FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as! NSNumber
checkBool(socketPermissions.intValue == 0o600, true, "control socket is private")
let directoryPermissions = try FileManager.default.attributesOfItem(atPath: testDirectory.path)[.posixPermissions] as! NSNumber
checkBool(directoryPermissions.intValue == 0o700, true, "control directory is private")

let completed = DispatchGroup()
completed.enter()
DispatchQueue.global().async {
    var results: [(Bool, String)] = []
    do {
        for (command, expected) in [(ControlCommand.status, false), (.on, true), (.on, true),
                                    (.status, true), (.off, false), (.off, false)] {
            let reply = try ControlSocket.request(command, path: socketPath)
            results.append((reply.ok && reply.status?.active == expected, "socket \(command) returns applied state"))
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(descriptor) }
        ControlSocket.configure(descriptor)
        var address = try ControlSocket.address(socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 {
            try ControlSocket.write(Data("toggle\n".utf8), to: descriptor)
            let reply = try JSONDecoder().decode(ControlReply.self, from: ControlSocket.readLine(from: descriptor))
            results.append((!reply.ok, "unknown socket command is rejected"))
        } else {
            results.append((false, "invalid-command test connects"))
        }
        do {
            _ = try ControlSocket.request(.on, path: socketPath + ".missing")
            results.append((false, "unavailable app returns an error"))
        } catch {
            results.append((true, "unavailable app returns an error"))
        }
    } catch {
        results.append((false, "socket round trip: \(error.localizedDescription)"))
    }
    let finalResults = results
    DispatchQueue.main.async {
        for (passed, name) in finalResults { checkBool(passed, true, name) }
        completed.leave()
    }
}
let deadline = Date().addingTimeInterval(15)
while completed.wait(timeout: .now()) != .success && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
checkBool(completed.wait(timeout: .now()) == .success, true, "socket tests complete within timeout")
server = nil
// Cancellation closes the listener before releasing the lifetime lock.
let stopDeadline = Date().addingTimeInterval(2)
while FileManager.default.fileExists(atPath: socketPath) && Date() < stopDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
checkBool(FileManager.default.fileExists(atPath: socketPath), false, "server removes its socket on shutdown")
try FileManager.default.removeItem(at: testDirectory)

if failures > 0 {
    print("\(failures) failing")
    exit(1)
} else {
    print("all passing")
    exit(0)
}
