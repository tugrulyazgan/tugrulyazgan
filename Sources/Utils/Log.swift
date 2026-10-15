import Foundation
import OSLog

// MARK: - Log Level

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }
}

// MARK: - Log

final class Log: @unchecked Sendable {
    static let shared = Log()

    let minimumLevel: LogLevel = .debug

    private let queue = DispatchQueue(label: "com.wangjiyuan.Lyrisland.logger")
    private let osLogger = Logger(subsystem: "com.wangjiyuan.Lyrisland", category: "app")
    private let logDirectory: URL
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var buffer: [String] = []
    private var fileHandle: FileHandle?
    private var currentDateString: String?
    private var flushTimer: DispatchSourceTimer?
    private let bufferFlushThreshold = 50
    private static let retentionDays = 30

    private init() {
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        logDirectory = libraryDir.appendingPathComponent("Logs/Lyrisland")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.flushBuffer()
        }
        timer.resume()
        flushTimer = timer
    }

    deinit {
        flushTimer?.cancel()
        flushTimer?.setEventHandler {}
    }

    // MARK: - Public API

    func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.debug, message(), file: file, line: line)
    }

    func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.info, message(), file: file, line: line)
    }

    func warning(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.warning, message(), file: file, line: line)
    }

    func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.error, message(), file: file, line: line)
    }

    func flush() {
        queue.sync { flushBuffer() }
    }

    func cleanupOldLogs() {
        queue.async { [weak self] in
            self?.performCleanup()
        }
    }

    // MARK: - Core

    private func log(_ level: LogLevel, _ message: @autoclosure () -> String, file: String, line: Int) {
        guard level >= minimumLevel else { return }

        let msg = message()
        let source = shortFileName(file)
        let now = Date()

        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = dateFormatter.string(from: now)
            let formatted = "\(timestamp) [\(level.label)] \(source):\(line) — \(msg)"

            // Forward to os.Logger
            osLogger.log(level: level.osLogType, "\(formatted, privacy: .public)")

            buffer.append(formatted)
            if buffer.count >= bufferFlushThreshold {
                flushBuffer()
            }
        }
    }

    // MARK: - Buffer & File (called on private queue)

    private func flushBuffer() {
        guard !buffer.isEmpty else { return }

        let today = fileDateFormatter.string(from: Date())
        if today != currentDateString {
            fileHandle?.closeFile()
            fileHandle = nil
            currentDateString = today
        }

        if fileHandle == nil {
            let filePath = logDirectory.appendingPathComponent("\(today).log")
            if !FileManager.default.fileExists(atPath: filePath.path) {
                FileManager.default.createFile(atPath: filePath.path, contents: nil)
            }
            fileHandle = FileHandle(forWritingAtPath: filePath.path)
            fileHandle?.seekToEndOfFile()
        }

        let text = buffer.joined(separator: "\n") + "\n"
        if let data = text.data(using: .utf8) {
            fileHandle?.write(data)
        }
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Cleanup

    private func performCleanup() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date()

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard let fileDate = fileDateFormatter.date(from: name) else { continue }
            if fileDate < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Helpers

    private func shortFileName(_ fileID: String) -> String {
        // #fileID gives "Module/File.swift" — extract just "File"
        let name = fileID.components(separatedBy: "/").last ?? fileID
        return name.replacingOccurrences(of: ".swift", with: "")
    }
}

// MARK: - Convenience Functions

func logDebug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    Log.shared.debug(message(), file: file, line: line)
}

func logInfo(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    Log.shared.info(message(), file: file, line: line)
}

func logWarning(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    Log.shared.warning(message(), file: file, line: line)
}

func logError(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    Log.shared.error(message(), file: file, line: line)
}
