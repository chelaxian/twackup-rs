//
//  DatabasePackageDetailedView.swift
//  Twackup
//
//  Created by Daniil on 29.11.2022.
//

import UIKit

protocol DatabasePackageDetailedViewDelegate: PackageDetailViewDelegate {
    func deleteDeb()
    func installDeb()
}

class DatabasePackageDetailedView: PackageDetailedView<DebPackage> {
    let debSizeLabel = KeyValueLabel(key: "detailed-view-debsize-lbl".localized)

    private lazy var deleteButton = actionButton(
        title: "remove-btn".localized,
        image: "trash",
        color: .systemRed,
        action: #selector(deletePackage)
    )

    private lazy var installButton = actionButton(
        title: "install-btn".localized,
        image: "wrench.and.screwdriver",
        color: .systemGreen,
        action: #selector(installPackage)
    )

    private lazy var actionsView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [deleteButton, installButton])
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.backgroundColor = .systemBackground
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 8, bottom: 16, right: 8)
        stack.isLayoutMarginsRelativeArrangement = true
        return stack
    }()

    private var actionsConstraints: [NSLayoutConstraint]?

    override init(delegate: PackageDetailViewDelegate) {
        super.init(delegate: delegate)

        sizesStackView.addArrangedSubview(debSizeLabel)
        addSubview(actionsView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func updateContents(forPackage package: DebPackage) {
        super.updateContents(forPackage: package)
        learnMoreButton.isHidden = true

        // float value comparement logic
        if package.debSize.value > 1 {
            debSizeLabel.valueLabel.text = ByteCountFormatter().string(from: package.debSize)
        } else {
            debSizeLabel.valueLabel.text = "unknown".localized
        }
    }

    override func updateConstraints() {
        super.updateConstraints()

        if actionsConstraints == nil {
            let safeArea = safeAreaLayoutGuide
            let constraints = [
                actionsView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                actionsView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
                actionsView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
            ]
            NSLayoutConstraint.activate(constraints)
            actionsConstraints = constraints
        }
    }

    private func actionButton(
        title: String,
        image: String,
        color: UIColor,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setTitle(title, for: .normal)
        button.setImage(UIImage(systemName: image), for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: UIFont.buttonFontSize, weight: .semibold)
        button.tintColor = color
        button.setTitleColor(color, for: .normal)
        button.backgroundColor = .quaternarySystemFill
        button.contentEdgeInsets = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -10, bottom: 0, right: 0)
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 20
        return button
    }

    @objc private func deletePackage() {
        (delegate as? any DatabasePackageDetailedViewDelegate)?.deleteDeb()
    }

    @objc private func installPackage() {
        (delegate as? any DatabasePackageDetailedViewDelegate)?.installDeb()
    }
}
