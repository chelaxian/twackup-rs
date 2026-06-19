//
//  Jailbreaks.swift
//  Twackup
//
//  Created by Daniil on 12.06.2024.
//

import Foundation

func jbRootPath(_ cPath: UnsafePointer<CChar>?) -> String {
    guard let resolved = libroot_dyn_jbrootpath(cPath, nil) else { return "" }
    let result = String(cString: resolved)
    free(resolved)

    return result
}

func jbRootPath<S: StringProtocol>(_ path: S) -> String {
    path.withCString { jbRootPath($0) }
}

func resolvedJailbreakPath(_ path: String) -> String {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: path) {
        return path
    }

    let librootPath = jbRootPath(path)
    if !librootPath.isEmpty, fileManager.fileExists(atPath: librootPath) {
        return librootPath
    }

    let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let rootlessPath = URL(fileURLWithPath: "/var/jb")
        .appendingPathComponent(relative)
        .path
    if fileManager.fileExists(atPath: rootlessPath) {
        return rootlessPath
    }

    let rootHideContainer = "/var/containers/Bundle/Application"
    guard let entries = try? fileManager.contentsOfDirectory(atPath: rootHideContainer) else {
        return path
    }

    let matches = entries
        .filter { $0.hasPrefix(".jbroot-") }
        .map {
            URL(fileURLWithPath: rootHideContainer)
                .appendingPathComponent($0)
                .appendingPathComponent(relative)
                .path
        }
        .filter { fileManager.fileExists(atPath: $0) }
        .sorted()

    return matches.last ?? path
}

func isRootlessOrRootHideBootstrap() -> Bool {
    resolvedJailbreakPath("/var/lib/dpkg") != "/var/lib/dpkg"
}
