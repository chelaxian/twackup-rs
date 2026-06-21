//
//  LogViewController.swift
//  Twackup
//
//  Created by Daniil on 09.12.2022.
//

import BlankSlate
import StyledTextKit

final class LogViewController: UIViewController, FFILoggerSubscriber, ScrollableViewController {
    let metadata: ViewControllerMetadata

    let mainModel: MainModel

    let currentText = NSMutableAttributedString()

    private var wantsToScrollBottom: Bool = false
    private var renderTask: Task<Void, Never>?

    private static let logHighWaterLength = 250_000
    private static let logTargetLength = 180_000

    private(set) lazy var logView: StyledTextView = {
        let view = StyledTextView()

        return view
    }()

    private(set) lazy var scrollView: UIScrollView = {
        let view = UIScrollView()
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.addSubview(logView)

        return view
    }()

    private(set) lazy var clearLogButton: UIBarButtonItem = {
        let title = "log-clear-btn".localized
        return UIBarButtonItem(title: title, style: .plain, target: self, action: #selector(actionClearLog))
    }()

    init(mainModel: MainModel, metadata: ViewControllerMetadata) {
        self.mainModel = mainModel
        self.metadata = metadata
        super.init(nibName: nil, bundle: nil)
        tabBarItem = metadata.tabbarItem

        Task {
            await FFILogger.shared.addSubscriber(self)
        }
    }

    deinit {
        renderTask?.cancel()
        Task { [self] in
            await FFILogger.shared.removeSubscriber(self)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = metadata.navTitle
        navigationItem.rightBarButtonItem = clearLogButton
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        renderLog()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        scrollToBottomIfNeeded()
    }

    private func renderLog() {
        guard currentText.length > 0 else {
            logView.isHidden = true
            scrollView.contentSize = .zero
            return
        }

        logView.isHidden = false
        let category = UIApplication.shared.preferredContentSizeCategory
        let builder = StyledTextBuilder(attributedText: currentText)
        let renderer = StyledTextRenderer(string: builder.build(), contentSizeCategory: category)
        logView.configure(with: renderer, width: view.bounds.width)

        scrollView.contentSize = logView.bounds.size
    }

    private func scheduleRender() {
        guard renderTask == nil else { return }

        renderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }

            self.renderTask = nil
            guard !Task.isCancelled, self.isViewLoaded, self.view.window != nil else { return }

            self.renderLog()
            self.scrollToBottomIfNeeded()
        }
    }

    private func trimLogIfNeeded() {
        guard currentText.length > Self.logHighWaterLength else { return }

        let minimumRemoval = currentText.length - Self.logTargetLength
        let searchLength = min(4_096, currentText.length - minimumRemoval)
        let searchRange = NSRange(location: minimumRemoval, length: searchLength)
        let newlineRange = (currentText.string as NSString).range(of: "\n", range: searchRange)
        let removalLength = newlineRange.location == NSNotFound
            ? minimumRemoval
            : NSMaxRange(newlineRange)

        currentText.deleteCharacters(in: NSRange(location: 0, length: removalLength))
    }

    private func scrollToBottomIfNeeded(animated: Bool = false) {
        guard wantsToScrollBottom else { return }
        wantsToScrollBottom = false

        let inset = scrollView.adjustedContentInset
        let minimumOffset = CGPoint(x: -inset.left, y: -inset.top)
        guard currentText.length > 0, scrollView.contentSize.height > 0 else {
            scrollView.setContentOffset(minimumOffset, animated: false)
            return
        }

        let maximumY = max(
            minimumOffset.y,
            scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: minimumOffset.x, y: maximumY),
            animated: animated
        )
    }

    @objc
    func actionClearLog() {
        renderTask?.cancel()
        renderTask = nil
        currentText.setAttributedString(NSAttributedString())
        renderLog()

        scrollView.contentOffset = scrollView.minimumContentOffset
    }

    // MARK: - FFILoggerSubscriber

    func log(message: FFILogger.Message, level: FFILogger.Level) async {
        await MainActor.run {
            let targetColor: UIColor = switch level {
            case .off: .clear
            case .debug: .systemIndigo
            case .info: .systemBlue
            case .warning: .systemOrange
            case .error: .systemRed
            }

            currentText.append(NSAttributedString(string: "[\(message.target ?? "nil")]  ", attributes: [
                .font: UIFont.boldSystemFont(ofSize: UIFont.systemFontSize),
                .foregroundColor: targetColor
            ]))

            currentText.append(NSAttributedString(string: message.text, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular),
                .foregroundColor: UIColor.label
            ]))

            currentText.append(NSAttributedString(string: "\n"))
            trimLogIfNeeded()

            wantsToScrollBottom = true
            if isViewLoaded, view.window != nil {
                scheduleRender()
            }
        }
    }

    func flush() async {
    }

    // MARK: - ScrollableViewController

    func scrollToInitialPosition(animated: Bool) {
        wantsToScrollBottom = true
        scrollToBottomIfNeeded(animated: animated)
    }
}
