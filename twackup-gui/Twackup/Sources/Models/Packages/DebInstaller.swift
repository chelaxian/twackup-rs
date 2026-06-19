//
//  DebInstaller.swift
//  Twackup
//
//  Created by Codex on 19.06.2026.
//

import Foundation

enum DebInstaller {
    enum Error: LocalizedError {
        case noPackages
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .noPackages:
                "No packages selected"
            case let .failed(status):
                "dpkg exited with status \(status)"
            }
        }
    }

    static func install(packages: [DebPackage]) async throws {
        guard !packages.isEmpty else {
            throw Error.noPackages
        }

        let paths = packages.map(\.fileURL.path)
        await FFILogger.shared.log("Installing \(paths.count) deb package(s)...", level: .info)

        let status = try await runDpkgInstall(paths: paths)
        guard status == 0 else {
            throw Error.failed(status)
        }

        await FFILogger.shared.log("dpkg install finished successfully", level: .info)
    }

    private static func runDpkgInstall(paths: [String]) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let quotedPaths = paths.map(shellQuote).joined(separator: " ")
            let command = """
            if [ -r /var/mobile/sudoi.pass ]; then \
              cat /var/mobile/sudoi.pass | sudo -S -p '' dpkg -i \(quotedPaths); \
            else \
              dpkg -i \(quotedPaths); \
            fi
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let handle = pipe.fileHandleForReading
            let reader = Task {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        break
                    }

                    buffer.append(chunk)
                    if let text = String(data: buffer, encoding: .utf8) {
                        await FFILogger.shared.log(text.trimmingCharacters(in: .whitespacesAndNewlines), level: .info)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }

            try process.run()
            process.waitUntilExit()
            handle.closeFile()
            await reader.value

            return process.terminationStatus
        }.value
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
