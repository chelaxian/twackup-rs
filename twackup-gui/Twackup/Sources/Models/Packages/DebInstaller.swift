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
        case timedOut(String)

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
            case let .timedOut(path):
                "dpkg install timed out while running \(path)"
            }
        }
    }

    static func install(packages: [DebPackage]) async throws {
        guard !packages.isEmpty else {
            throw Error.noPackages
        }

        try await performInstall(packages: packages)
    }

    private static func performInstall(packages: [DebPackage]) async throws {

        emitLog("Staging \(packages.count) deb package(s)...", level: .info)

        let staged = try await stageArchives(packages)
        defer { staged.cleanup() }

        emitLog("Installing \(staged.paths.count) deb package(s)...", level: .info)

        let result = try await runDpkgInstall(paths: staged.paths)
        if !result.output.isEmpty {
            emitLog(result.output, level: result.status == 0 ? .info : .error)
        }

        let status = result.status
        guard status == 0 else {
            if result.output.isEmpty {
                throw Error.failed(status)
            }
            throw Error.failedWithOutput(status, result.output)
        }

        emitLog("dpkg install finished successfully", level: .info)
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

    private actor RcRootWarmup {
        static let shared = RcRootWarmup()
        private var isPrepared = false

        func prepare(executable: String) throws {
            guard !isPrepared else { return }

            let pid = try DebInstaller.spawnRcRootWarmup(executable: executable)
            usleep(1_000_000)
            DebInstaller.stopRcRootWarmup(pid: pid)
            isPrepared = true
        }
    }

    static func stageArchives(
        _ packages: [DebPackage],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StagedArchives {
        let logicalRoot = URL(
            fileURLWithPath: "/var/mobile/Library/Caches/Twackup/Install",
            isDirectory: true
        )
        let stagingRoot: URL
        if Bundle.main.bundlePath.contains("/.jbroot-") {
            let jailbreakRoot = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            stagingRoot = jailbreakRoot
                .appendingPathComponent("var/mobile/Library/Caches/Twackup/Install", isDirectory: true)
        } else {
            stagingRoot = logicalRoot
        }

        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let directory = stagingRoot
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
        let jailbreakRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let physicalRcRoot = jailbreakRoot
            .appendingPathComponent("usr/bin/rc-root")
            .path

        return try await Task.detached(priority: .userInitiated) {
            let token = UUID().uuidString
            let logPath = "/tmp/twackup-dpkg-install-\(token).log"
            let executable: String
            let arguments: [String]
            let completionPath: String?
            if getuid() == 0, FileManager.default.isExecutableFile(atPath: "/usr/bin/dpkg") {
                executable = "/usr/bin/dpkg"
                arguments = [executable, "-i"] + paths
                completionPath = nil
            } else if !FileManager.default.isExecutableFile(atPath: physicalRcRoot),
                      FileManager.default.isExecutableFile(atPath: "/usr/bin/sudo"),
                      FileManager.default.isExecutableFile(atPath: "/usr/bin/dash"),
                      FileManager.default.isExecutableFile(atPath: "/usr/bin/dpkg"),
                      FileManager.default.isReadableFile(atPath: "/var/mobile/sudoi.pass") {
                let stagingDirectory = URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path
                completionPath = "\(stagingDirectory)/.twackup-install.status"
                let scriptPath = "\(stagingDirectory)/.twackup-install.sh"
                let quotedPaths = paths.map(shellQuote).joined(separator: " ")
                let script = """
                /usr/bin/dpkg -i \(quotedPaths)
                status=$?
                printf '%s' "$status" > \(shellQuote(completionPath!))
                exit $status
                """
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                guard chmod(scriptPath, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
                    throw Error.spawnFailed(errno, scriptPath)
                }
                let command = "exec /usr/bin/sudo -S -p '' /usr/bin/dash \(shellQuote(scriptPath)) < /var/mobile/sudoi.pass"
                executable = "/usr/bin/dash"
                arguments = [executable, "-c", command]
            } else if FileManager.default.isExecutableFile(atPath: physicalRcRoot) {
                executable = physicalRcRoot
                let stagingDirectory = URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path
                completionPath = "\(stagingDirectory)/.twackup-install.status"
                let scriptPath = "\(stagingDirectory)/.twackup-install.sh"
                let quotedPaths = paths.map(shellQuote).joined(separator: " ")
                let script = """
                /usr/bin/dpkg -i \(quotedPaths)
                status=$?
                printf '%s' "$status" > \(shellQuote(completionPath!))
                exit $status
                """
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                guard chmod(scriptPath, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
                    throw Error.spawnFailed(errno, scriptPath)
                }
                arguments = [executable, "/usr/bin/dash", scriptPath]
            } else {
                let shellPath = bootstrapPath("/usr/bin/dash")
                let sudoPath = bootstrapPath("/usr/bin/sudo")
                let dpkgPath = bootstrapPath("/usr/bin/dpkg")
                let quotedPaths = paths.map(shellQuote).joined(separator: " ")
                let command = "exec \(shellQuote(sudoPath)) -S -p '' \(shellQuote(dpkgPath)) -i \(quotedPaths) < /var/mobile/sudoi.pass"
                executable = shellPath
                arguments = [shellPath, "-c", command]
                completionPath = nil
            }

            if executable == physicalRcRoot {
                try await RcRootWarmup.shared.prepare(executable: physicalRcRoot)
            }

            let launcherStatus = try runProcess(
                executable: executable,
                arguments: arguments,
                standardInput: "/dev/null",
                logPath: logPath
            )
            let status: Int32
            if let completionPath {
                status = try waitForCompletionMarker(at: completionPath)
                let scriptPath = URL(fileURLWithPath: completionPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent(".twackup-install.sh")
                    .path
                try? FileManager.default.removeItem(atPath: scriptPath)
            } else {
                status = launcherStatus
            }
            let output = (try? String(contentsOfFile: logPath))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(atPath: logPath)

            return DpkgResult(status: status, output: output)
        }.value
    }

    private static func waitForCompletionMarker(at path: String) throws -> Int32 {
        let timeout = Date().addingTimeInterval(180)
        while Date() < timeout {
            if let value = try? String(contentsOfFile: path),
               let status = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                try? FileManager.default.removeItem(atPath: path)
                return status
            }
            usleep(100_000)
        }
        throw Error.timedOut("/usr/bin/dpkg")
    }

    private static func spawnRcRootWarmup(executable: String) throws -> pid_t {
        let nullFD = open("/dev/null", O_RDWR)
        guard nullFD >= 0 else {
            throw Error.spawnFailed(errno, "/dev/null")
        }
        defer { close(nullFD) }

        var fileActions: posix_spawn_file_actions_t?
        var actionStatus = posix_spawn_file_actions_init(&fileActions)
        guard actionStatus == 0 else {
            throw Error.spawnFailed(actionStatus, executable)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var spawnAttributes: posix_spawnattr_t?
        actionStatus = posix_spawnattr_init(&spawnAttributes)
        guard actionStatus == 0 else {
            throw Error.spawnFailed(actionStatus, executable)
        }
        defer { posix_spawnattr_destroy(&spawnAttributes) }

        actionStatus = posix_spawnattr_setflags(
            &spawnAttributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        )
        guard actionStatus == 0 else {
            throw Error.spawnFailed(actionStatus, executable)
        }
        actionStatus = posix_spawnattr_setpgroup(&spawnAttributes, 0)
        guard actionStatus == 0 else {
            throw Error.spawnFailed(actionStatus, executable)
        }

        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            actionStatus = posix_spawn_file_actions_adddup2(&fileActions, nullFD, descriptor)
            guard actionStatus == 0 else {
                throw Error.spawnFailed(actionStatus, executable)
            }
        }

        var pid = pid_t()
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(executable),
            strdup("/usr/bin/true"),
            nil
        ]
        var env: [UnsafeMutablePointer<CChar>?] = [
            strdup("PATH=/usr/bin:/bin"),
            strdup("HOME=/var/mobile"),
            strdup("USER=mobile"),
            strdup("LOGNAME=mobile"),
            nil
        ]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            env.compactMap { $0 }.forEach { free($0) }
        }

        let spawnStatus = posix_spawn(
            &pid,
            executable,
            &fileActions,
            &spawnAttributes,
            &argv,
            &env
        )
        guard spawnStatus == 0 else {
            throw Error.spawnFailed(spawnStatus, executable)
        }
        return pid
    }

    private static func stopRcRootWarmup(pid: pid_t) {
        _ = kill(-pid, SIGTERM)
        _ = kill(pid, SIGTERM)
        usleep(100_000)

        var status: Int32 = 0
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        _ = waitpid(pid, &status, WNOHANG)
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        standardInput: String,
        logPath: String
    ) throws -> Int32 {
        let inputFD = open(standardInput, O_RDONLY)
        guard inputFD >= 0 else {
            throw Error.spawnFailed(errno, standardInput)
        }
        defer { close(inputFD) }

        let outputFD = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard outputFD >= 0 else {
            throw Error.spawnFailed(errno, logPath)
        }
        defer { close(outputFD) }

        var fileActions: posix_spawn_file_actions_t?
        var actionStatus = posix_spawn_file_actions_init(&fileActions)
        guard actionStatus == 0 else {
            throw Error.spawnFailed(actionStatus, executable)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        actionStatus = posix_spawn_file_actions_adddup2(&fileActions, inputFD, STDIN_FILENO)
        guard actionStatus == 0 else { throw Error.spawnFailed(actionStatus, executable) }
        actionStatus = posix_spawn_file_actions_adddup2(&fileActions, outputFD, STDOUT_FILENO)
        guard actionStatus == 0 else { throw Error.spawnFailed(actionStatus, executable) }
        actionStatus = posix_spawn_file_actions_adddup2(&fileActions, outputFD, STDERR_FILENO)
        guard actionStatus == 0 else { throw Error.spawnFailed(actionStatus, executable) }

        var pid = pid_t()
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var env: [UnsafeMutablePointer<CChar>?] = [
            strdup("PATH=/usr/bin:/bin:/var/jb/usr/bin:/var/jb/bin"),
            strdup("HOME=/var/mobile"),
            strdup("USER=mobile"),
            strdup("LOGNAME=mobile"),
            nil
        ]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            env.compactMap { $0 }.forEach { free($0) }
        }

        let spawnStatus = posix_spawn(&pid, executable, &fileActions, nil, &argv, &env)
        guard spawnStatus == 0 else {
            throw Error.spawnFailed(spawnStatus, executable)
        }

        let timeout = Date().addingTimeInterval(180)
        var waitStatus: Int32 = 0
        while true {
            let waitedPID = waitpid(pid, &waitStatus, WNOHANG)
            if waitedPID == 0 {
                if Date() >= timeout {
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, &waitStatus, 0)
                    throw Error.timedOut(executable)
                }
                usleep(100_000)
                continue
            }
            if waitedPID == -1 && errno == EINTR {
                continue
            }
            guard waitedPID == pid else {
                throw Error.waitFailed(errno)
            }
            break
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

    private static func emitLog(_ text: String, level: FFILogger.Level) {
        Task(priority: .utility) {
            await FFILogger.shared.log(text, level: level)
        }
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

    static func stage(package: DebPackage) async throws -> PreparedArchive {
        let staged = try await DebInstaller.stageArchives([package])
        guard let path = staged.paths.first else {
            staged.cleanup()
            throw DebInstaller.Error.noPackages
        }
        return PreparedArchive(url: URL(fileURLWithPath: path), directory: staged.directory)
    }

    static func make(
        packages: [DebPackage],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedArchive {
        let files = packages.map(\.fileURL)

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
                    files: files,
                    progress: progress
                )
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
        let totalWork = max(fileSizes.reduce(UInt64(0), +), 1)
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

            let localOffset = offset
            var header = Data()
            header.appendLE(UInt32(0x04034b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0808))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt32(0))
            header.appendLE(UInt32(0))
            header.appendLE(UInt32(0))
            header.appendLE(UInt16(name.count))
            header.appendLE(UInt16(0))
            header.append(name)
            try output.write(contentsOf: header)
            offset += UInt32(header.count)

            var crc = UInt32.max
            do {
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try output.write(contentsOf: data)
                    for byte in data {
                        crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
                    }
                    offset += UInt32(data.count)
                    completedWork += UInt64(data.count)
                    progress(min(Double(completedWork) / Double(totalWork), 1.0))
                }
            }

            crc ^= UInt32.max
            var descriptor = Data()
            descriptor.appendLE(UInt32(0x08074b50))
            descriptor.appendLE(crc)
            descriptor.appendLE(UInt32(fileSize))
            descriptor.appendLE(UInt32(fileSize))
            try output.write(contentsOf: descriptor)
            offset += UInt32(descriptor.count)

            entries.append(Entry(name: name, crc32: crc, size: UInt32(fileSize), offset: localOffset))
        }

        let centralOffset = offset
        for entry in entries {
            var header = Data()
            header.appendLE(UInt32(0x02014b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0808))
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
