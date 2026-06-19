//
//  DatabaseDetailVC.swift
//  Twackup
//
//  Created by Daniil on 29.11.2022.
//

import UIKit

class DatabaseDetailVC: PackageDetailVC<DebPackage> {
    private lazy var _container = DatabasePackageDetailedView(delegate: self)
    override var detailView: PackageDetailedView<DebPackage> { _container }

    private lazy var shareDebButton: UIBarButtonItem = {
        UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareDeb))
    }()

    private lazy var deleteDebButton: UIBarButtonItem = {
        UIBarButtonItem(title: "remove-btn".localized, style: .plain, target: self, action: #selector(deleteDeb))
    }()

    private lazy var installDebButton: UIBarButtonItem = {
        UIBarButtonItem(title: "install-btn".localized, style: .plain, target: self, action: #selector(installDeb))
    }()

    override var package: DebPackage? {
        didSet {
            navigationItem.rightBarButtonItem = package != nil ? shareDebButton : nil
            configureToolbar()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureToolbar()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    @objc
    func shareDeb(_ button: UIBarButtonItem) {
        guard let package else { return }

        let activityVC = UIActivityViewController(activityItems: [package.fileURL], applicationActivities: nil)
        activityVC.popoverPresentationController?.barButtonItem = button
        present(activityVC, animated: true, completion: nil)
    }

    @objc
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

    @objc
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
                    NotificationCenter.default.post(name: .DebsReload, object: nil)
                    navigationController?.popViewController(animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "cancel".localized, style: .cancel))
        present(alert, animated: true)
    }

    private func configureToolbar() {
        guard package != nil else {
            navigationController?.setToolbarHidden(true, animated: false)
            return
        }

        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        setToolbarItems([deleteDebButton, spacer, installDebButton], animated: false)
        navigationController?.setToolbarHidden(false, animated: false)
    }

    private func showResult(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ok".localized, style: .default))
        present(alert, animated: true)
    }
}
