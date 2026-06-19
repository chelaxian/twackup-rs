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

        await FFILogger.shared.log("Staging \(packages.count) deb package(s)...", level: .info)

        let staged = try await stageArchives(packages)
        defer { staged.cleanup() }

        await FFILogger.shared.log("Installing \(staged.paths.count) deb package(s)...", level: .info)

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

    struct StagedArchives {
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

    static func stageArchives(
        _ packages: [DebPackage],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StagedArchives {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("twackup-install-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let totalBytes = max(packages.reduce(Int64(0)) {
                $0 + Int64($1.debSize.converted(to: .bytes).value)
            }, 1)
            var copiedBytes = Int64(0)
            var stagedPaths = [String]()
            do {
                for package in packages {
                    let safeName = package.id
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: ":", with: "_")
                    let destination = directory.appendingPathComponent("\(safeName)_\(package.version).deb")

                    try streamCopyArchive(from: package.fileURL, to: destination) { count in
                        copiedBytes += Int64(count)
                        progress?(min(Double(copiedBytes) / Double(totalBytes), 1.0))
                    }
                    stagedPaths.append(destination.path)
                }
            } catch {
                try? fileManager.removeItem(at: directory)
                throw error
            }

            return StagedArchives(directory: directory, paths: stagedPaths)
        }.value
    }

    private static func streamCopyArchive(
        from source: URL,
        to destination: URL,
        progress: ((Int) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw Error.missingArchive(destination.path)
        }

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw Error.missingArchive("\(source.path): \(error.localizedDescription)")
        }

        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }

        while true {
            let data = try input.read(upToCount: 1024 * 1024)
            guard let data, !data.isEmpty else {
                break
            }

            try output.write(contentsOf: data)
            progress?(data.count)
        }

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw Error.missingArchive("\(source.path): staged archive is empty")
        }
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


enum DebShareArchive {
    struct PreparedArchive {
        let url: URL
        private let directory: URL

        fileprivate init(url: URL, directory: URL) {
            self.url = url
            self.directory = directory
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func make(
        packages: [DebPackage],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedArchive {
        let staged = try await DebInstaller.stageArchives(packages) { value in
            progress(value * 0.34)
        }
        defer { staged.cleanup() }

        return try await Task.detached(priority: .userInitiated) {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("twackup-share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let archiveURL = directory
                .appendingPathComponent("Twackup-Backup-\(formatter.string(from: Date())).zip")

            do {
                try StoredZipArchive.create(
                    at: archiveURL,
                    files: staged.paths.map { URL(fileURLWithPath: $0) }
                ) { value in
                    progress(0.34 + value * 0.66)
                }
                progress(1.0)
                return PreparedArchive(url: archiveURL, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }
}

private enum StoredZipArchive {
    private struct Entry {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func create(
        at destination: URL,
        files: [URL],
        progress: (Double) -> Void
    ) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DebInstaller.Error.missingArchive(destination.path)
        }

        let fileSizes = try files.map { file -> UInt64 in
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        }
        let totalWork = max(fileSizes.reduce(UInt64(0), +) * 2, 1)
        var completedWork = UInt64(0)

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var entries = [Entry]()
        var offset: UInt32 = 0

        for (index, file) in files.enumerated() {
            let fileSize = fileSizes[index]
            guard fileSize <= UInt32.max else {
                throw DebInstaller.Error.missingArchive("\(file.lastPathComponent): file is too large for ZIP32")
            }

            let name = Data(file.lastPathComponent.utf8)
            guard name.count <= Int(UInt16.max) else {
                throw DebInstaller.Error.missingArchive("\(file.lastPathComponent): filename is too long")
            }

            let crc = try crc32(of: file) { count in
                completedWork += UInt64(count)
                progress(min(Double(completedWork) / Double(totalWork), 1.0))
            }
            let localOffset = offset
            var header = Data()
            header.appendLE(UInt32(0x04034b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(crc)
            header.appendLE(UInt32(fileSize))
            header.appendLE(UInt32(fileSize))
            header.appendLE(UInt16(name.count))
            header.appendLE(UInt16(0))
            header.append(name)
            try output.write(contentsOf: header)
            offset += UInt32(header.count)

            do {
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try output.write(contentsOf: data)
                    offset += UInt32(data.count)
                    completedWork += UInt64(data.count)
                    progress(min(Double(completedWork) / Double(totalWork), 1.0))
                }
            }

            entries.append(Entry(name: name, crc32: crc, size: UInt32(fileSize), offset: localOffset))
        }

        let centralOffset = offset
        for entry in entries {
            var header = Data()
            header.appendLE(UInt32(0x02014b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(entry.crc32)
            header.appendLE(entry.size)
            header.appendLE(entry.size)
            header.appendLE(UInt16(entry.name.count))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt32(0))
            header.appendLE(entry.offset)
            header.append(entry.name)
            try output.write(contentsOf: header)
            offset += UInt32(header.count)
        }

        let centralSize = offset - centralOffset
        guard entries.count <= Int(UInt16.max) else {
            throw DebInstaller.Error.missingArchive("too many files for ZIP32")
        }

        var end = Data()
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(centralSize)
        end.appendLE(centralOffset)
        end.appendLE(UInt16(0))
        try output.write(contentsOf: end)
    }

    private static func crc32(of file: URL, progress: (Int) -> Void) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }

        var value = UInt32.max
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            for byte in data {
                value = table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
            }
            progress(data.count)
        }
        return value ^ UInt32.max
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
