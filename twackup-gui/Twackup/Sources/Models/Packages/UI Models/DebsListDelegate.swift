//
//  DebsListDelegate.swift
//  Twackup
//
//  Created by Daniil on 17.06.2024.
//

class DebsListDelegate: PackageListDelegate<DebPackage> {
    let debsDataSource: DebsListDataSource

    private(set) weak var debsListController: DebsListVC?

    init(dataSource: DebsListDataSource, listController: DebsListVC) {
        debsDataSource = dataSource
        debsListController = listController

        super.init(dataSource: dataSource, listController: listController)
    }

    @objc(tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:)
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let package = self.debsDataSource.package(for: indexPath) else { return nil }

        let delete = UIContextualAction(style: .destructive, title: "remove-btn".localized) { _, _, completion in
            self.debsListController?.askAndDelete(packages: [package])
            completion(true)
        }
        delete.image = UIImage(systemName: "trash.fill")

        let install = UIContextualAction(style: .normal, title: "install-btn".localized) { _, _, completion in
            self.debsListController?.install(packages: [package])
            completion(true)
        }
        install.image = UIImage(systemName: "wrench.and.screwdriver.fill") ?? UIImage(systemName: "wrench.fill")
        install.backgroundColor = .systemGreen

        return UISwipeActionsConfiguration(actions: [delete, install])
    }

    @objc(tableView:contextMenuConfigurationForRowAtIndexPath:point:)
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let package = self.debsDataSource.package(for: indexPath) else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyID = UIAction(title: "copy-id".localized, image: UIImage(systemName: "paperclip")) { _ in
                UIPasteboard.general.string = package.id
            }

            let remove = UIAction(
                title: "remove-btn".localized,
                image: UIImage(systemName: "trash"),
                attributes: [.destructive]
            ) { _ in
                self.debsListController?.askAndDelete(packages: [package])
            }

            let install = UIAction(
                title: "install-btn".localized,
                image: UIImage(systemName: "wrench.and.screwdriver") ?? UIImage(systemName: "wrench")
            ) { _ in
                self.debsListController?.install(packages: [package])
            }

            var children = [copyID, install, remove]

            // valid url so it's safe to unwrap
            let filzaURL = URL(string: "filza://\(package.fileURL.path)")!
            if UIApplication.shared.canOpenURL(filzaURL) {
                let image = UIImage(systemName: "arrowshape.turn.up.right")
                children.insert(UIAction(title: "view-in-filza".localized, image: image) { _ in
                    UIApplication.shared.open(filzaURL)
                }, at: 0)
            }

            return UIMenu(children: children)
        }
    }
}
