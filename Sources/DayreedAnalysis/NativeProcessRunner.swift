import DayreedCore
import Darwin
import Foundation

/// Explicit executable/arguments/environment; never constructs or invokes a shell command.
/// A poll loop bounds stdin/stdout/stderr and enforces cancellation even if the CLI ignores SIGTERM.
struct NativeProcessRunner: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String], directory: URL,
             input: Data, timeout: Double, outputLimit: Int = 1_024 * 1_024) async throws -> Data {
        guard input.count <= 16 * 1_024 * 1_024, timeout.isFinite, timeout > 0 else { throw AnalysisError.inputTooLarge }
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let result = try execute(executable: executable, arguments: arguments, environment: environment,
                            directory: directory, input: input, timeout: timeout, outputLimit: outputLimit, cancellation: cancellation)
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func execute(executable: URL, arguments: [String], environment: [String: String], directory: URL,
                         input: Data, timeout: Double, outputLimit: Int, cancellation: ProcessCancellation) throws -> Data {
        guard !cancellation.isCancelled else { throw AnalysisError.cancelled }
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AnalysisError.processFailed
        }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = directory
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let reader = stdout.fileHandleForReading.fileDescriptor
        let errorReader = stderr.fileHandleForReading.fileDescriptor
        let writer = stdin.fileHandleForWriting.fileDescriptor
        for descriptor in [reader, errorReader, writer] {
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else { throw AnalysisError.processFailed }
        }
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw AnalysisError.processFailed }
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        defer {
            try? stdin.fileHandleForWriting.close(); try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                // This is the exact process started above, never a process discovered by name.
                let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
                while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var sent = 0, errorBytes = 0
        var output = Data()
        var inputOpen = true, outputOpen = true, errorOpen = true
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while process.isRunning || outputOpen || errorOpen {
            if cancellation.isCancelled { throw AnalysisError.cancelled }
            if Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 >= timeout { throw AnalysisError.timedOut }
            if inputOpen && sent == input.count { try? stdin.fileHandleForWriting.close(); inputOpen = false }
            var descriptors = [
                pollfd(fd: outputOpen ? reader : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorOpen ? errorReader : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputOpen ? writer : -1, events: Int16(POLLOUT), revents: 0),
            ]
            let polled = poll(&descriptors, nfds_t(descriptors.count), 20)
            if polled < 0 && errno != EINTR { throw AnalysisError.processFailed }
            for index in 0...1 where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = read(descriptors[index].fd, &buffer, buffer.count)
                if count > 0 {
                    if index == 0 {
                        guard output.count + count <= outputLimit else { throw AnalysisError.outputTooLarge }
                        output.append(contentsOf: buffer.prefix(count))
                    } else {
                        errorBytes += count
                        guard errorBytes <= outputLimit else { throw AnalysisError.outputTooLarge }
                    }
                } else if count == 0 {
                    if index == 0 { outputOpen = false } else { errorOpen = false }
                } else if errno != EAGAIN && errno != EINTR { throw AnalysisError.processFailed }
            }
            if inputOpen && descriptors[2].revents != 0 {
                let count = input.withUnsafeBytes { raw in
                    write(writer, raw.baseAddress!.advanced(by: sent), min(16_384, input.count - sent))
                }
                if count > 0 { sent += count }
                else if count < 0 && errno == EPIPE { try? stdin.fileHandleForWriting.close(); inputOpen = false }
                else if count < 0 && errno != EAGAIN && errno != EINTR { throw AnalysisError.processFailed }
            }
        }
        process.waitUntilExit()
        guard !cancellation.isCancelled else { throw AnalysisError.cancelled }
        guard process.terminationReason == .exit && process.terminationStatus == 0 else { throw AnalysisError.processFailed }
        guard !output.isEmpty else { throw AnalysisError.emptyResponse }
        return output
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
