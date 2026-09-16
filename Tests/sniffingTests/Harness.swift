import Foundation

/// Runs the built `sniffing` binary against fake `pmset`, `sudo` and `osascript` scripts
/// that record every call and keep the lid-sleep setting in a file.
struct Harness {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private final class Marker {}

    let dir: URL
    private let stateFile: URL
    private let logFile: URL
    private var extraEnv: [String: String] = [:]

    /// - Parameters:
    ///   - lidDisabled: the initial `pmset disablesleep` value the fake reports.
    ///   - denyPasswordlessSudo: fake `sudo -n` fails, as it does without a sudoers rule.
    ///   - denySudo: fake `sudo` fails in every form.
    init(lidDisabled: Bool = false, denyPasswordlessSudo: Bool = false, denySudo: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sniffing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateFile = dir.appendingPathComponent("state")
        logFile = dir.appendingPathComponent("log")
        try (lidDisabled ? "1" : "0").write(to: stateFile, atomically: true, encoding: .utf8)
        try "".write(to: logFile, atomically: true, encoding: .utf8)

        try install("pmset", script: """
        #!/bin/sh
        echo "pmset $*" >> "$SNIFFING_TEST_LOG"
        case "$1" in
          -g)
            printf 'System-wide power settings:\\n'
            if [ "$(cat "$SNIFFING_TEST_STATE")" = 1 ]; then printf ' SleepDisabled\\t\\t1\\n'; fi
            printf 'Currently in use:\\n standby              1\\n sleep                1\\n'
            ;;
          -c)
            if [ "$2" = disablesleep ]; then printf '%s' "$3" > "$SNIFFING_TEST_STATE"; fi
            ;;
          *)
            echo "fake pmset: unexpected args $*" >&2
            exit 99
            ;;
        esac
        """)
        try install("sudo", script: """
        #!/bin/sh
        echo "sudo $*" >> "$SNIFFING_TEST_LOG"
        if [ "${FAKE_SUDO_DENY_ALL:-}" = 1 ]; then echo "sudo: denied" >&2; exit 1; fi
        if [ "$1" = -n ]; then
          shift
          if [ "${FAKE_SUDO_DENY_N:-}" = 1 ]; then echo "sudo: a password is required" >&2; exit 1; fi
        else
          # An interactive prompt only works from the caller's process group.
          echo "pgid self=$(ps -o pgid= -p $$ | tr -d ' ') parent=$(ps -o pgid= -p $PPID | tr -d ' ')" >> "$SNIFFING_TEST_LOG"
        fi
        exec "$@"
        """)
        try install("osascript", script: """
        #!/bin/sh
        echo "osascript $*" >> "$SNIFFING_TEST_LOG"
        cmd=$(printf '%s' "$2" | sed -E 's/^do shell script "(.*)" with administrator privileges$/\\1/')
        if [ -z "$cmd" ]; then echo "fake osascript: unexpected script $2" >&2; exit 99; fi
        exec sh -c "$cmd"
        """)

        if denyPasswordlessSudo { extraEnv["FAKE_SUDO_DENY_N"] = "1" }
        if denySudo { extraEnv["FAKE_SUDO_DENY_ALL"] = "1" }
    }

    private func install(_ name: String, script: String) throws {
        let url = dir.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The setting as the fake `pmset` last stored it.
    var lidDisabled: Bool {
        get throws { try String(contentsOf: stateFile, encoding: .utf8) == "1" }
    }

    /// Every command the fakes were invoked with, in order.
    var calls: [String] {
        get throws {
            try String(contentsOf: logFile, encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
    }

    var fakePmset: String { dir.appendingPathComponent("pmset").path }

    /// Run with stdin attached to a pseudo-terminal, as from an interactive shell.
    @discardableResult
    func runFromTerminal(_ args: String...) throws -> Result {
        var primary = Int32(0), replica = Int32(0)
        guard openpty(&primary, &replica, nil, nil, nil) == 0 else { throw HarnessError.noPTY }
        defer { close(primary); close(replica) }
        return try run(args, stdin: FileHandle(fileDescriptor: replica, closeOnDealloc: false))
    }

    @discardableResult
    func run(_ args: String...) throws -> Result {
        try run(args, stdin: FileHandle.nullDevice)
    }

    private func run(_ args: [String], stdin: FileHandle) throws -> Result {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["SNIFFING_PMSET"] = fakePmset
        env["SNIFFING_SUDO"] = dir.appendingPathComponent("sudo").path
        env["SNIFFING_OSASCRIPT"] = dir.appendingPathComponent("osascript").path
        env["SNIFFING_TEST_STATE"] = stateFile.path
        env["SNIFFING_TEST_LOG"] = logFile.path
        extraEnv.forEach { env[$0.key] = $0.value }
        process.environment = env
        process.standardInput = stdin
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // A hang here means CLI mode fell through into the menu bar app.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw HarnessError.timedOut(args)
        }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    enum HarnessError: Error {
        case timedOut([String])
        case noPTY
    }

    /// The `sniffing` executable SwiftPM built next to this test bundle.
    private static let binary: URL = Bundle(for: Marker.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("sniffing")

    /// What the real machine is drawing from right now, from the real `pmset`.
    static var machineOnCharger: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return out.contains("'AC Power'")
    }
}
