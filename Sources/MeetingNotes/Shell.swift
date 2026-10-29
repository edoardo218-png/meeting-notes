import Foundation

struct ShellError: LocalizedError {
    let command: String
    let status: Int32
    let stderr: String
    var stdout: String = ""
    var timedOut = false
    var errorDescription: String? {
        let name = (command as NSString).lastPathComponent
        if timedOut { return "\(name) non ha risposto in tempo ed è stato interrotto." }
        // Alcuni programmi (es. la CLI di Claude: "Please run /login") scrivono l'errore su stdout.
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
        return "\(name) è uscito con codice \(status): \(detail.trimmingCharacters(in: .whitespacesAndNewlines).suffix(800))"
    }
}

enum Shell {
    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
        var timedOut = false
    }

    /// Esegue un processo, opzionalmente passando `input` su stdin. Non blocca il main thread se chiamato da un Task.
    @discardableResult
    static func run(_ executable: String,
                    _ args: [String],
                    input: String? = nil,
                    cwd: URL? = nil,
                    env: [String: String] = [:],
                    check: Bool = true,
                    timeout: TimeInterval = 1800) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try runSync(executable, args, input: input, cwd: cwd, env: env, timeout: timeout)
                    if r.timedOut {
                        cont.resume(throwing: ShellError(command: executable, status: r.status, stderr: r.stderr, stdout: r.stdout, timedOut: true))
                    } else if check && r.status != 0 {
                        cont.resume(throwing: ShellError(command: executable, status: r.status, stderr: r.stderr, stdout: r.stdout))
                    } else {
                        cont.resume(returning: r)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(_ executable: String, _ args: [String], input: String?,
                                cwd: URL?, env: [String: String], timeout: TimeInterval) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        // PATH ragionevole anche quando l'app è lanciata dal Finder.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", Config.expandTilde("~/.local/bin")]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        for (k, v) in env { environment[k] = v }
        p.environment = environment

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = Pipe()
        p.standardInput = input != nil ? inPipe : FileHandle.nullDevice

        // Leggiamo stdout/stderr in parallelo per evitare deadlock con output lunghi.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        try p.run()
        if let input {
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
        }
        // Timeout: un processo bloccato (es. LLM che non risponde) non deve fermare l'elaborazione per sempre.
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()
        return Result(stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      status: p.terminationStatus, timedOut: timedOut)
    }
}
