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
        case missingArchive(String)
        case failed(Int32)
        case failedWithOutput(Int32, String)
        case spawnFailed(Int32, String)
        case waitFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .noPackages:
                "No packages selected"
            case let .missingArchive(path):
                "DEB archive is not readable: \(path)"
            case let .failed(status):
                "dpkg exited with status \(status)"
            case let .failedWithOutput(status, output):
                "dpkg exited with status \(status):\n\(output)"
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

        let staged = try stageArchives(packages)
        defer { staged.cleanup() }

        let result = try await runDpkgInstall(paths: staged.paths)
        if !result.output.isEmpty {
            await FFILogger.shared.log(result.output, level: result.status == 0 ? .info : .error)
        }

        let status = result.status
        guard status == 0 else {
            if result.output.isEmpty {
                throw Error.failed(status)
            }
            throw Error.failedWithOutput(status, result.output)
        }

        await FFILogger.shared.log("dpkg install finished successfully", level: .info)
    }

    private struct StagedArchives {
        let directory: URL
        let paths: [String]

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct DpkgResult {
        let status: Int32
        let output: String
    }

    private static func stageArchives(_ packages: [DebPackage]) throws -> StagedArchives {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("twackup-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var stagedPaths = [String]()
        do {
            for package in packages {
                guard fileManager.isReadableFile(atPath: package.fileURL.path) else {
                    throw Error.missingArchive(package.fileURL.path)
                }

                let safeName = package.id
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                let destination = directory.appendingPathComponent("\(safeName)_\(package.version).deb")
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }

                try fileManager.copyItem(at: package.fileURL, to: destination)
                stagedPaths.append(destination.path)
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        return StagedArchives(directory: directory, paths: stagedPaths)
    }

    private static func runDpkgInstall(paths: [String]) async throws -> DpkgResult {
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
            let output = (try? String(contentsOfFile: logPath))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(atPath: logPath)

            return DpkgResult(status: status, output: output)
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
