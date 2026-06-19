//
//  DebsListVC.swift
//  Twackup
//
//  Created by Daniil on 01.12.2022.
//

import BlankSlate

final class DebsListVC: SelectablePackageListVC<DebPackage> {
    override class var metadata: (any ViewControllerMetadata)? {
        BuildedPkgsMetadata()
    }

    var debsDataSource: DebsListDataSource {
        dataSource as! DebsListDataSource // swiftlint:disable:this force_cast
    }

    private let databaseProvider: DatabasePackageProvider

    private(set) lazy var removeAllBarBtn: UIBarButtonItem = {
        UIBarButtonItem(title: "debs-remove-all-btn".localized, primaryAction: UIAction { [self] _ in
            setEditing(false, animated: true)
            askAndDelete(packages: databaseProvider.allPackages)
        })
    }()

    private(set) lazy var removeSelectedBarBtn: UIBarButtonItem = {
        UIBarButtonItem(title: "remove-btn".localized, primaryAction: UIAction { [self] _ in
            askAndDelete(packages: dataSource.selected())
        })
    }()

    private(set) lazy var installSelectedBarBtn: UIBarButtonItem = {
        UIBarButtonItem(title: "install-btn".localized, primaryAction: UIAction { [self] _ in
            install(packages: dataSource.selected())
        })
    }()

    private(set) lazy var shareSelectedBarBtn: UIBarButtonItem = {
        let title = "debs-share-btn".localized
        return UIBarButtonItem(title: title, style: .plain, target: self, action: #selector(actionShareSelected))
    }()

    private var reloadObserver: NSObjectProtocol?

    override init(mainModel: MainModel, detail: PackageDetailVC<DebPackage>) {
        databaseProvider = DatabasePackageProvider(mainModel.database)

        super.init(mainModel: mainModel, detail: detail)

        let center = NotificationCenter.default
        reloadObserver = center.addObserver(forName: .DebsReload, object: nil, queue: .main) { [weak self] _ in
            self?.reloadData(animated: true, force: true)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        Task { @MainActor [self] in
            NotificationCenter.default.removeObserver(reloadObserver as Any)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.bs.dataSource = self
    }

    override func selectionDidUpdate() {
        super.selectionDidUpdate()

        if isEditing {
            let isAnySelected = dataSource.isAnySelected

            shareSelectedBarBtn.isEnabled = isAnySelected
            installSelectedBarBtn.isEnabled = isAnySelected
            guard var buttons = toolbarItems, !buttons.isEmpty else { return }
            buttons[0] = isAnySelected ? removeSelectedBarBtn : removeAllBarBtn
            setToolbarItems(buttons, animated: false)
        }
    }

    override func configureDataSource() -> PackageListDataSource<DebPackage> {
        let cell = DebTableViewCell.self
        let cellID = String(describing: cell)
        tableView.register(cell, forCellReuseIdentifier: cellID)

        return DebsListDataSource(tableView: tableView, dataProvider: databaseProvider) { table, indexPath, package in
            let cell = table.dequeueReusableCell(withIdentifier: cellID, for: indexPath)
            if let cell = cell as? DebTableViewCell {
                cell.package = package
            }

            return cell
        }
    }

    override func configureTableDelegate() -> PackageListDelegate<DebPackage> {
        DebsListDelegate(dataSource: debsDataSource, listController: self)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)

        if editing {
            shareSelectedBarBtn.isEnabled = false
            installSelectedBarBtn.isEnabled = false

            let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            setToolbarItems([removeAllBarBtn, spacer, installSelectedBarBtn, spacer, shareSelectedBarBtn], animated: false)
        }

        navigationController?.setToolbarHidden(!editing, animated: animated)
    }

    // MARK: - Actions

    @objc
    func actionShareSelected(_ button: UIBarButtonItem) {
        let packages = dataSource.selected()
        guard !packages.isEmpty else { return }

        if packages.count == 1, let package = packages.first {
            presentShareSheet(items: [package.fileURL], source: button)
            return
        }

        button.isEnabled = false
        let hud = Hud.show()
        hud?.style = .arc
        hud?.text = "ZIP"
        hud?.detailedText = "0%"
        hud?.setProgress(0.0, animated: false)

        Task {
            do {
                let archive = try await DebShareArchive.make(packages: packages) { value in
                    Task { @MainActor in
                        let percent = Int((value * 100.0).rounded())
                        hud?.detailedText = "\(percent)%"
                        hud?.setProgress(CGFloat(value), animated: true)
                    }
                }
                await hud?.hide(animated: true)
                button.isEnabled = true
                presentShareSheet(items: [archive.url], source: button) {
                    archive.cleanup()
                }
            } catch {
                await FFILogger.shared.log(error.localizedDescription, level: .error)
                await hud?.hide(animated: true)
                button.isEnabled = true
                showShareError(error.localizedDescription)
            }
        }
    }

    private func presentShareSheet(
        items: [Any],
        source button: UIBarButtonItem,
        cleanup: (() -> Void)? = nil
    ) {
        let activities = items.compactMap { $0 as? URL }.first.flatMap { url in
            FilzaExportActivity.canOpenFilza ? [FilzaExportActivity(fileURL: url)] : nil
        }
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: activities)
        activityVC.popoverPresentationController?.barButtonItem = button
        activityVC.completionWithItemsHandler = { _, _, _, _ in cleanup?() }
        present(activityVC, animated: true, completion: nil)
    }

    private func showShareError(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ok".localized, style: .default))
        present(alert, animated: true)
    }

    func askAndDelete(packages: [DebPackage]) {
        let alert = UIAlertController(
            title: "deb-remove-alert-title".localized,
            message: "deb-remove-alert-subtitle".localized,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "deb-remove-alert-ok".localized, style: .destructive) { [self] _ in
            Task {
                await debsDataSource.delete(packages: packages)
            }
        })

        alert.addAction(UIAlertAction(title: "cancel".localized, style: .cancel))

        present(alert, animated: true)
    }

    func install(packages: [DebPackage]) {
        guard !packages.isEmpty else { return }

        let alert = UIAlertController(
            title: "deb-install-alert-title".localized,
            message: "deb-install-alert-subtitle".localized,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "install-btn".localized, style: .default) { [self] _ in
            Task {
                do {
                    try await DebInstaller.install(packages: packages)
                    await MainActor.run {
                        showInstallResult(success: true, message: "deb-install-success".localized)
                    }
                } catch {
                    await FFILogger.shared.log(error.localizedDescription, level: .error)
                    await MainActor.run {
                        showInstallResult(success: false, message: error.localizedDescription)
                    }
                }
            }
        })

        alert.addAction(UIAlertAction(title: "cancel".localized, style: .cancel))
        present(alert, animated: true)
    }

    private func showInstallResult(success: Bool, message: String) {
        let alert = UIAlertController(
            title: success ? "deb-install-success-title".localized : "deb-install-failure-title".localized,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "ok".localized, style: .default))
        present(alert, animated: true)
    }
}

private final class FilzaExportActivity: UIActivity {
    private static let filzaProbeURL = URL(string: "filza://view")!

    static var canOpenFilza: Bool {
        UIApplication.shared.canOpenURL(filzaProbeURL)
    }

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
    }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("ru.danpashin.twackup.open-in-filza")
    }

    override var activityTitle: String? {
        "Filza"
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "folder.fill")
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        Self.canOpenFilza && activityItems.contains { $0 is URL }
    }

    override func perform() {
        do {
            let exportsDirectory = URL(fileURLWithPath: "/var/mobile/Documents/Twackup", isDirectory: true)
            try FileManager.default.createDirectory(
                at: exportsDirectory,
                withIntermediateDirectories: true
            )

            let destination = exportsDirectory.appendingPathComponent(fileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)

            var components = URLComponents()
            components.scheme = "filza"
            components.host = "view"
            components.path = destination.path
            guard let filzaURL = components.url else {
                activityDidFinish(false)
                return
            }

            UIApplication.shared.open(filzaURL) { [weak self] opened in
                self?.activityDidFinish(opened)
            }
        } catch {
            activityDidFinish(false)
        }
    }
}
