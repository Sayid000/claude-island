//
//  FileLogger.swift
//  ClaudeIsland
//
//  Simple file logger for debugging
//

import Foundation

class FileLogger {
    static let shared = FileLogger()
    private let logFile: URL
    private let queue = DispatchQueue(label: "com.claudeisland.filelogger")

    private init() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        logFile = documentsDirectory.appendingPathComponent("claude-island-debug.log")

        // Clear previous log
        try? FileManager.default.removeItem(at: logFile)
    }

    func log(_ message: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let timestamp = DateFormatter().string(from: Date())
            let logMessage = "[\(timestamp)] \(message)\n"

            if let handle = FileHandle(forWritingAtPath: self.logFile.path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                try? logMessage.data(using: .utf8)?.write(to: self.logFile)
            }

            // Also print to console
            print(message)
        }
    }

    func readLog() -> String {
        if let data = try? Data(contentsOf: logFile),
           let content = String(data: data, encoding: .utf8) {
            return content
        }
        return ""
    }
}
