//
//  SettingsViewController.swift
//  Twackup
//
//  Created by Daniil on 13.12.2022.
//

import Darwin
import SwiftUI

struct SettingsViewController: View {
    let metadata: ViewControllerMetadata

    let mainModel: MainModel

    @ObservedObject private var preferences: Preferences

    @State private var showClearDataAlert = false
    @State private var respringAlert: RespringAlert?

    let diskUsageView: DiskSpaceUsage

    init(mainModel: MainModel, metadata: ViewControllerMetadata) {
        self.mainModel = mainModel
        self.metadata = metadata
        self.preferences = mainModel.preferences

        diskUsageView = DiskSpaceUsage(mainModel: mainModel)
    }

    var body: some View {
        NavigationView {
            List {
                Section(content: {
                    Picker("settings-compression-level", selection: preferences.compression.$level) {
                        ForEach(Compression.Level.allCases) { element in
                            Text(element.localized).tag(element)
                        }
                    }

                    Picker("settings-compression-type", selection: preferences.$compression.kind) {
                        ForEach(Compression.Kind.allCases) { element in
                            Text(element.localized).tag(element)
                        }
                    }
                }, header: {
                    Text("settings-compression-header")
                }, footer: {
                    Text("settings-compression-footer")
                })

                Section(content: {
                    Toggle("settings-follow-symlinks", isOn: $preferences.followSymlinks)
                }, footer: {
                    Text("settings-follow-symlinks-footer")
                })

                Section(content: {
                    diskUsageView
                        .padding(.vertical, 8.0)
                    Button("settings-clear-appdata-button") {
                        showClearDataAlert = true
                    }
                    .alert(isPresented: $showClearDataAlert) {
                        Alert(
                            title: Text("settings-clear-appdata-warning-title"),
                            message: Text("settings-clear-appdata-warning-message"),
                            primaryButton: .cancel(),
                            secondaryButton: .destructive(
                                Text("settings-clear-appdata-warning-clear-anyway"),
                                action: clearAppData
                            )
                        )
                    }
                }, header: {
                    Text("settings-disk-usage-header")
                })

                Section(content: {
                    Button {
                        respringAlert = .confirmation
                    } label: {
                        Label("settings-respring-button", systemImage: "arrow.clockwise")
                    }
                    .alert(item: $respringAlert) { alert in
                        switch alert {
                        case .confirmation:
                            Alert(
                                title: Text("settings-respring-confirm-title"),
                                message: Text("settings-respring-confirm-message"),
                                primaryButton: .cancel(),
                                secondaryButton: .destructive(Text("settings-respring-confirm-button")) {
                                    performRespring()
                                }
                            )
                        case let .failure(message):
                            Alert(
                                title: Text("settings-respring-error-title"),
                                message: Text(message),
                                dismissButton: .default(Text("ok"))
                            )
                        }
                    }

                    Link(
                        "settings-donate-button",
                        destination: URL(string: "https://my.qiwi.com/Danyyl-PFxEvxeqrC")!
                    )
                    Link(
                        "settings-reportabug-button",
                        destination: URL(string: "https://github.com/danpashin/twackup-rs/issues/new")!
                    )
                    DetailedLabelSUI(
                        "settings-app-version-label",
                        detailed: Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "unknown".localized
                    )
                }, footer: {
                    Text("Copyright (c) 2022 danpashin. All rights reserved")
                })
            }
            .listStyle(.insetGrouped)
            .navigationTitle(metadata.navTitle)
        }
        .navigationViewStyle(.stack)
    }

    func clearAppData() {
        Task {
            try? await mainModel.databasePackageProvider.deleteAll()
            NotificationCenter.default.post(name: .DebsReload, object: nil)
        }
    }

    func performRespring() {
        Task {
            do {
                try await RespringAction.run()
            } catch {
                await FFILogger.shared.log(error.localizedDescription, level: .error)
                respringAlert = .failure(error.localizedDescription)
            }
        }
    }
}

private enum RespringAlert: Identifiable {
    case confirmation
    case failure(String)

    var id: String {
        switch self {
        case .confirmation: "confirmation"
        case .failure: "failure"
        }
    }
}

private enum RespringAction {
    enum Error: LocalizedError {
        case unavailable
        case spawnFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "sbreload is not available"
            case let .spawnFailed(status):
                "sbreload could not start: \(String(cString: strerror(status)))"
            }
        }
    }

    static func run() async throws {
        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            bundleRoot.appendingPathComponent("usr/bin/sbreload").path,
            resolvedJailbreakPath("/usr/bin/sbreload"),
            "/usr/bin/sbreload"
        ]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw Error.unavailable
        }

        try await Task.detached(priority: .userInitiated) {
            var pid = pid_t()
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
            var env: [UnsafeMutablePointer<CChar>?] = [
                strdup("PATH=/usr/bin:/bin:/var/jb/usr/bin:/var/jb/bin"),
                strdup("HOME=/var/mobile"),
                strdup("USER=mobile"),
                nil
            ]
            defer {
                argv.compactMap { $0 }.forEach { free($0) }
                env.compactMap { $0 }.forEach { free($0) }
            }

            let status = posix_spawn(&pid, executable, nil, nil, &argv, &env)
            guard status == 0 else {
                throw Error.spawnFailed(status)
            }
        }.value
    }
}
