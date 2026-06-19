//
//  DebInstaller.swift
//  Twackup
//
//  Created by Codex on 19.06.2026.
//

import Darwin
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
        await Task.detached(priority: .userInitiated) {
            let quotedPaths = paths.map(shellQuote).joined(separator: " ")
            let logPath = "/tmp/twackup-dpkg-install-\(UUID().uuidString).log"
            let quotedLogPath = shellQuote(logPath)
            let command = """
            if [ -r /var/mobile/sudoi.pass ]; then \
              cat /var/mobile/sudoi.pass | sudo -S -p '' dpkg -i \(quotedPaths); \
            else \
              dpkg -i \(quotedPaths); \
            fi > \(quotedLogPath) 2>&1
            """

            let rawStatus = system(command)
            if let output = try? String(contentsOfFile: logPath), !output.isEmpty {
                await FFILogger.shared.log(output.trimmingCharacters(in: .whitespacesAndNewlines), level: .info)
            }
            try? FileManager.default.removeItem(atPath: logPath)

            guard rawStatus != -1 else { return -1 }
            return Int32((rawStatus >> 8) & 0xff)
        }.value
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
