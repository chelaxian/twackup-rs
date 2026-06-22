//
//  DatabaseDetailVC.swift
//  Twackup
//
//  Created by Daniil on 29.11.2022.
//

import UIKit

class DatabaseDetailVC: PackageDetailVC<DebPackage>, DatabasePackageDetailedViewDelegate {
    private lazy var _container = DatabasePackageDetailedView(delegate: self)
    override var detailView: PackageDetailedView<DebPackage> { _container }

    private lazy var shareDebButton: UIBarButtonItem = {
        UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareDeb))
    }()

    override var package: DebPackage? {
        didSet {
            navigationItem.rightBarButtonItem = package != nil ? shareDebButton : nil
        }
    }

    @objc
    func shareDeb(_ button: UIBarButtonItem) {
        guard let package else { return }

        button.isEnabled = false
        Task {
            do {
                let staged = try await DebShareArchive.stage(package: package)
                button.isEnabled = true
                let filzaURL = URL(string: "filza://view")!
                let activities = UIApplication.shared.canOpenURL(filzaURL)
                    ? [FilzaExportActivity(fileURL: staged.url)]
                    : nil
                let activityVC = UIActivityViewController(
                    activityItems: [staged.url],
                    applicationActivities: activities
                )
                activityVC.popoverPresentationController?.barButtonItem = button
                activityVC.completionWithItemsHandler = { _, _, _, _ in staged.cleanup() }
                present(activityVC, animated: true)
            } catch {
                await FFILogger.shared.log(error.localizedDescription, level: .error)
                button.isEnabled = true
                showResult(title: "deb-install-failure-title".localized, message: error.localizedDescription)
            }
        }
    }

    func installDeb() {
        guard let package else { return }

        Task {
            do {
                try await DebInstaller.install(packages: [package])
                await MainActor.run {
                    showResult(title: "deb-install-success-title".localized, message: "deb-install-success".localized)
                }
            } catch {
                await FFILogger.shared.log(error.localizedDescription, level: .error)
                await MainActor.run {
                    showResult(title: "deb-install-failure-title".localized, message: error.localizedDescription)
                }
            }
        }
    }

    func deleteDeb() {
        guard let package else { return }

        let alert = UIAlertController(
            title: "deb-remove-alert-title".localized,
            message: "deb-remove-alert-subtitle".localized,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "deb-remove-alert-ok".localized, style: .destructive) { [self] _ in
            Task {
                try? await mainModel.database.delete(package: package)
                await MainActor.run {
                    self.package = nil
                    NotificationCenter.default.post(name: .DebsReload, object: nil)
                    returnToDebsList()
                }
            }
        })
        alert.addAction(UIAlertAction(title: "cancel".localized, style: .cancel))
        present(alert, animated: true)
    }

    private func returnToDebsList() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
            return
        }

        if let splitViewController {
            splitViewController.show(.primary)
        }
    }

    private func showResult(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ok".localized, style: .default))
        present(alert, animated: true)
    }
}
