// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa
import WalletConnect
import LocalAuthentication

class Agent: NSObject {

    static let shared = Agent()
    private lazy var statusImage = NSImage(named: "Status")
    
    private override init() { super.init() }
    private var statusBarItem: NSStatusItem!
    private var hasPassword = Keychain.password != nil
    private var didEnterPasswordOnStart = false
    var statusBarButtonIsBlocked = false
    
    func start() {
        checkPasteboardAndOpen(onAppStart: true)
    }
    
    func reopen() {
        checkPasteboardAndOpen(onAppStart: false)
    }
    
    func showInitialScreen(wcSession: WCSession?) {
        let windowController = Window.showNew()
        
        guard hasPassword else {
            let welcomeViewController = WelcomeViewController.new { [weak self] createdPassword in
                guard createdPassword else { return }
                self?.didEnterPasswordOnStart = true
                self?.hasPassword = true
                self?.showInitialScreen(wcSession: wcSession)
            }
            windowController.contentViewController = welcomeViewController
            return
        }
        
        guard didEnterPasswordOnStart else {
            askAuthentication(on: windowController.window, requireAppPasswordScreen: true, reason: "Start") { [weak self] success in
                if success {
                    self?.didEnterPasswordOnStart = true
                    self?.showInitialScreen(wcSession: wcSession)
                }
            }
            return
        }
        
        let completion = onSelectedAccount(session: wcSession)
        let accounts = AccountsService.getAccounts()
        if !accounts.isEmpty {
            let accountsList = AccountsListViewController.with(preloadedAccounts: accounts)
            accountsList.onSelectedAccount = completion
            windowController.contentViewController = accountsList
        } else {
            let importViewController = instantiate(ImportViewController.self)
            importViewController.onSelectedAccount = completion
            windowController.contentViewController = importViewController
        }
    }
    
    func showApprove(title: String, meta: String, completion: @escaping (Bool) -> Void) {
        let windowController = Window.showNew()
        let approveViewController = ApproveViewController.with(title: title, meta: meta) { [weak self] result in
            if result {
                self?.askAuthentication(on: windowController.window, requireAppPasswordScreen: false, reason: title) { success in
                    completion(success)
                    Window.closeAllAndActivateBrowser()
                }
            } else {
                Window.closeAllAndActivateBrowser()
                completion(result)
            }
        }
        windowController.contentViewController = approveViewController
    }
    
    func showErrorMessage(_ message: String) {
        let windowController = Window.showNew()
        windowController.contentViewController = ErrorViewController.withMessage(message)
    }
    
    func processInputLink(_ link: String) {
        let session = sessionWithLink(link)
        showInitialScreen(wcSession: session)
    }
    
    func getAccountSelectionCompletionIfShouldSelect() -> ((Account) -> Void)? {
        let session = getSessionFromPasteboard()
        return onSelectedAccount(session: session)
    }
    
    lazy private var statusBarMenu: NSMenu = {
        let menu = NSMenu(title: "Encrypted Ink")
        let quitItem = NSMenuItem(title: "Quit", action: #selector(didSelectQuitMenuItem), keyEquivalent: "q")
        quitItem.target = self
        menu.delegate = self
        menu.addItem(quitItem)
        return menu
    }()
    
    func warnBeforeQuitting(updateStatusBarAfterwards: Bool = false) {
        Window.activateWindow(nil)
        let alert = Alert()
        alert.messageText = "Quit Encrypted Ink?"
        alert.informativeText = "You won't be able to sign requests."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
        if updateStatusBarAfterwards {
            setupStatusBarItem()
        }
    }
    
    @objc private func didSelectQuitMenuItem() {
        warnBeforeQuitting()
    }
    
    func setupStatusBarItem() {
        let statusBar = NSStatusBar.system
        statusBarItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem.button?.image = statusImage
        statusBarItem.button?.target = self
        statusBarItem.button?.action = #selector(statusBarButtonClicked(sender:))
        statusBarItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    
    @objc private func statusBarButtonClicked(sender: NSStatusBarButton) {
        guard !statusBarButtonIsBlocked else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            statusBarItem.menu = statusBarMenu
            statusBarItem.button?.performClick(nil)
        } else {
            checkPasteboardAndOpen(onAppStart: false)
        }
    }
    
    private func onSelectedAccount(session: WCSession?) -> ((Account) -> Void)? {
        guard let session = session else { return nil }
        return { [weak self] account in
            self?.connectWallet(session: session, account: account)
        }
    }
    
    private func getSessionFromPasteboard() -> WCSession? {
        let pasteboard = NSPasteboard.general
        let link = pasteboard.string(forType: .string) ?? ""
        let session = sessionWithLink(link)
        if session != nil {
            pasteboard.clearContents()
        }
        return session
    }
    
    private func checkPasteboardAndOpen(onAppStart: Bool) {
        let session = getSessionFromPasteboard()
        showInitialScreen(wcSession: session)
    }
    
    private func sessionWithLink(_ link: String) -> WCSession? {
        return WalletConnect.shared.sessionWithLink(link)
    }
    
    func askAuthentication(on: NSWindow?, getBackTo: NSViewController? = nil, requireAppPasswordScreen: Bool, reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        
        let canDoLocalAuthentication = context.canEvaluatePolicy(policy, error: &error)
        let willShowPasswordScreen = !canDoLocalAuthentication || requireAppPasswordScreen
        
        var passwordViewController: PasswordViewController?
        if willShowPasswordScreen {
            passwordViewController = PasswordViewController.with(mode: .enter,
                                                                 reason: reason,
                                                                 isDisabledOnStart: canDoLocalAuthentication) { [weak on, weak context] success in
                if let getBackTo = getBackTo {
                    on?.contentViewController = getBackTo
                } else {
                    Window.closeAll()
                }
                if success {
                    context?.invalidate()
                }
                completion(success)
            }
            on?.contentViewController = passwordViewController
        }
        
        if canDoLocalAuthentication {
            context.localizedCancelTitle = "Cancel"
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason ) { [weak on, weak passwordViewController] success, _ in
                DispatchQueue.main.async {
                    passwordViewController?.enableInput()
                    if !success && willShowPasswordScreen && on?.isVisible == true {
                        Window.activateWindow(on)
                    }
                    completion(success)
                }
            }
        }
    }
    
    private func connectWallet(session: WCSession, account: Account) {
        WalletConnect.shared.connect(session: session, address: account.address) { [weak self] connected in
            if connected {
                Window.closeAllAndActivateBrowser()
            } else {
                self?.showErrorMessage("Failed to connect")
            }
        }
        
        let windowController = Window.showNew()
        windowController.contentViewController = WaitingViewController.withReason("Connecting")
    }
    
}

extension Agent: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        statusBarItem.menu = nil
    }
    
}
