import AppKit
import CryptoKit

/// Runs the `shortcut` and `script` kinds of action: the selection goes in on
/// standard input (or as the Shortcut's input file), whatever comes out is the
/// result.
enum ProcessRunner {

    private static let log = FileLog("PopBar.Process")

    enum Failure: Error {
        case timedOut
        case exited(Int32, String)
        case couldNotStart(String)
    }

    /// Shell scripts get 10 s; a Shortcut may talk to other apps or the network,
    /// so it gets 30.
    static let scriptTimeout: TimeInterval = 10
    static let shortcutTimeout: TimeInterval = 30

    /// `MTOOL_TEXT` counts against the argument-and-environment limit (1 MB on
    /// macOS), so a huge selection would stop the script from starting at all.
    /// Standard input carries it regardless; the variable is a convenience.
    static let environmentTextLimit = 64 * 1024

    // MARK: - Script

    /// Run `script` with the user's login shell, so tools installed by Homebrew
    /// and the like are on the PATH exactly as in their terminal.
    static func runScript(_ script: String, input: String) async -> Result<String, Failure> {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        if input.utf8.count <= environmentTextLimit { env["MTOOL_TEXT"] = input }
        return await run(URL(fileURLWithPath: shell), ["-l", "-c", script], stdin: input,
                         environment: env, timeout: scriptTimeout)
    }

    // MARK: - Shortcut

    /// Run a Shortcut by name through the system `shortcuts` tool, with the
    /// selection as its input file and its output file read back.
    static func runShortcut(_ name: String, input: String) async -> Result<String, Failure> {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtool-shortcut-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(.couldNotStart(error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let inFile = dir.appendingPathComponent("input.txt")
        let outFile = dir.appendingPathComponent("output.txt")
        do {
            try input.write(to: inFile, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.couldNotStart(error.localizedDescription))
        }
        let result = await run(URL(fileURLWithPath: "/usr/bin/shortcuts"),
                               ["run", name, "--input-path", inFile.path, "--output-path", outFile.path],
                               stdin: nil, environment: nil, timeout: shortcutTimeout)
        switch result {
        case .failure(let failure):
            return .failure(failure)
        case .success(let stdout):
            // A Shortcut that ends in "Stop and Output" writes the file; one that
            // does not may still print. Either counts as its result.
            let written = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
            return .success(written.isEmpty ? stdout : written)
        }
    }

    // MARK: - Process

    private static func run(_ executable: URL, _ arguments: [String], stdin: String?,
                            environment: [String: String]?, timeout: TimeInterval) async -> Result<String, Failure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                let out = Pipe(), err = Pipe(), inPipe = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

                // Read both pipes while the process runs: a child that fills a
                // pipe buffer (64 KB) would otherwise block forever on its write.
                let outBox = DataBox(), errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outBox.set(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                group.enter()
                DispatchQueue.global().async { errBox.set(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }

                // Set BEFORE launching: a command that exits at once could otherwise
                // finish before the handler exists, and the wait below would run to
                // its full timeout and report one that never happened.
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }

                do {
                    try process.run()
                } catch {
                    log.error("could not start \(executable.lastPathComponent): \(error.localizedDescription)")
                    // The readers above are waiting for EOF on pipes nobody will
                    // ever write to; closing the write ends lets them finish.
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                    continuation.resume(returning: .failure(.couldNotStart(error.localizedDescription)))
                    return
                }
                if let stdin {
                    let writer = inPipe.fileHandleForWriting
                    // A script that exits without reading its input closes the pipe
                    // under us, and writing to a closed pipe raises SIGPIPE — which
                    // would terminate this whole app. Ask for an error instead.
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                    DispatchQueue.global().async {
                        try? writer.write(contentsOf: Data(stdin.utf8))
                        try? writer.close()
                    }
                }

                var timedOut = false
                let deadline = DispatchTime.now() + timeout
                if finished.wait(timeout: deadline) == .timedOut {
                    timedOut = true
                    process.terminate()
                    // A child that ignores SIGTERM still has to go.
                    if finished.wait(timeout: .now() + 1) == .timedOut {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                // Normally the pipes reach EOF as soon as the process is gone. A
                // background child it left behind (`cmd &`) keeps them open, and
                // waiting for that child could take forever — so after a short
                // grace the output is given up on (the readers finish on their own
                // whenever the child does).
                if group.wait(timeout: .now() + 2) == .timedOut {
                    log.info("\(executable.lastPathComponent): output still open after exit (a background child?) — not waiting for it")
                }
                let outData = outBox.get(), errData = errBox.get()

                if timedOut {
                    log.info("\(executable.lastPathComponent) timed out after \(Int(timeout)) s")
                    continuation.resume(returning: .failure(.timedOut))
                    return
                }
                let stdout = String(decoding: outData, as: UTF8.self)
                let stderr = String(decoding: errData, as: UTF8.self)
                // Privacy: exit status and sizes, never the text.
                log.debug("\(executable.lastPathComponent) exited \(process.terminationStatus), \(outData.count) byte(s) out")
                if process.terminationStatus != 0 {
                    continuation.resume(returning: .failure(.exited(process.terminationStatus, stderr)))
                } else {
                    // One trailing newline is the shell's, not the result's.
                    continuation.resume(returning: .success(stdout.hasSuffix("\n") ? String(stdout.dropLast()) : stdout))
                }
            }
        }
    }
}

/// Which shell scripts the user has agreed to run.
///
/// The config file is meant to be shared and committed, so a script in it may
/// have been written by someone else. The first time a given script runs, the
/// user sees its text and agrees to it. The agreement is keyed by a hash of the
/// exact text — an edited script asks again — and is kept in the app's own
/// defaults, NEVER in the config file: a shared config must not be able to
/// approve itself.
enum ScriptApproval {

    private static let key = "approvedScriptHashes"

    static func hash(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isApproved(_ script: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(hash(script))
    }

    static func approve(_ script: String) {
        var hashes = UserDefaults.standard.stringArray(forKey: key) ?? []
        let h = hash(script)
        guard !hashes.contains(h) else { return }
        hashes.append(h)
        UserDefaults.standard.set(hashes, forKey: key)
    }

    /// Ask, showing the script. Main thread only. The app is a menu-bar app with
    /// no window in front, so it has to come forward for the alert to be seen.
    static func ask(title: String, script: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("script.approve.title"), title)
        alert.informativeText = L("script.approve.body")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        text.string = script
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("script.approve.run"))
        alert.addButton(withTitle: L("script.approve.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Lets a reader thread hand its data over to a caller that may stop waiting
/// for it: the read and the handover never touch the same bytes at once.
private final class DataBox {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
