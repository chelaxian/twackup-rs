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
        case spawnFailed(Int32, String)
        case waitFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .noPackages:
                "No packages selected"
            case let .failed(status):
                "dpkg exited with status \(status)"
            case let .spawnFailed(status, path):
                "failed to launch \(path): \(String(cString: strerror(status)))"
            case let .waitFailed(status):
                "failed to wait for dpkg: \(String(cString: strerror(status)))"
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
            let logPath = "/tmp/twackup-dpkg-install-\(UUID().uuidString).log"
            let quotedLogPath = shellQuote(logPath)
            let shellPath = bootstrapPath("/usr/bin/dash")
            let sudoPath = bootstrapPath("/usr/bin/sudo")
            let dpkgPath = bootstrapPath("/usr/bin/dpkg")
            let command = """
            if [ -r /var/mobile/sudoi.pass ]; then \
              cat /var/mobile/sudoi.pass | \(shellQuote(sudoPath)) -S -p '' \(shellQuote(dpkgPath)) -i \(quotedPaths); \
            else \
              \(shellQuote(dpkgPath)) -i \(quotedPaths); \
            fi > \(quotedLogPath) 2>&1
            """

            let status = try runShell(command, shellPath: shellPath)
            if let output = try? String(contentsOfFile: logPath), !output.isEmpty {
                await FFILogger.shared.log(output.trimmingCharacters(in: .whitespacesAndNewlines), level: .info)
            }
            try? FileManager.default.removeItem(atPath: logPath)

            return status
        }.value
    }

    private static func runShell(_ command: String, shellPath: String) throws -> Int32 {
        var pid = pid_t()
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(shellPath),
            strdup("-c"),
            strdup(command),
            nil
        ]
        var env: [UnsafeMutablePointer<CChar>?] = [
            strdup("PATH=\(bootstrapPath("/usr/bin")):\(bootstrapPath("/bin")):/usr/bin:/bin"),
            nil
        ]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            env.compactMap { $0 }.forEach { free($0) }
        }

        let spawnStatus = posix_spawn(&pid, shellPath, nil, nil, &argv, &env)
        guard spawnStatus == 0 else {
            throw Error.spawnFailed(spawnStatus, shellPath)
        }

        var waitStatus: Int32 = 0
        guard waitpid(pid, &waitStatus, 0) == pid else {
            throw Error.waitFailed(errno)
        }

        if (waitStatus & 0x7f) != 0 {
            return waitStatus
        }

        return (waitStatus >> 8) & 0xff
    }

    private static func bootstrapPath(_ path: String) -> String {
        let fileManager = FileManager.default
        let librootPath = jbRootPath(path)
        if !librootPath.isEmpty, fileManager.fileExists(atPath: librootPath) {
            return librootPath
        }

        return resolvedJailbreakPath(path)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
