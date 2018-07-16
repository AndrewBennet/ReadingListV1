import UIKit
import SVProgressHUD
import SwiftyStoreKit
import CoreData
import GoogleSignIn
import GoogleAPIClientForREST
import GTMSessionFetcher

var appDelegate: AppDelegate {
    return UIApplication.shared.delegate as! AppDelegate
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var storeMigrationFailed = false

    var tabBarController: TabBarController {
        return window!.rootViewController as! TabBarController
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        UserEngagement.initialiseUserAnalytics()

        setupSvProgressHud()
        completeStoreTransactions()

        // Grab any options which we take action on after the persistent store is initialised
        let quickAction = launchOptions?[UIApplicationLaunchOptionsKey.shortcutItem] as? UIApplicationShortcutItem
        let csvFileUrl = launchOptions?[UIApplicationLaunchOptionsKey.url] as? URL
        
        
        // Setup Google Drive backup
        GIDSignIn.sharedInstance().clientID = "938491889218-vmj28rh94j2m51e1nv7i86rqn44va528.apps.googleusercontent.com"
        GIDSignIn.sharedInstance().delegate = self
        GoogleDriveBackup.DriveBackup.setup()

        // Initialise the persistent store on a background thread. The main thread will return and the LaunchScreen
        // storyboard will remain in place until this is completed, at which point the Main storyboard will be instantiated.
        DispatchQueue.global(qos: .userInteractive).async { [unowned self] in
            do {
                try PersistentStoreManager.initalisePersistentStore {
                    DispatchQueue.main.async {
                        #if DEBUG
                            DebugSettings.initialiseFromCommandLine()
                        #endif
                        self.window!.rootViewController = TabBarController()

                        // Initialise app-level theme, and monitor the set theme
                        self.initialiseTheme()
                        self.monitorThemeSetting()
                        UserSettings.mostRecentWorkingVersion.value = BuildInfo.appVersion

                        // Once the store is loaded and the main storyboard instantiated, perform the quick action
                        // or open the CSV file, is specified. This is done here rather than in application:open, for example,
                        // in the case where the app is not yet launched.
                        if let quickAction = quickAction {
                            self.performQuickAction(QuickAction(rawValue: quickAction.type)!)
                        } else if let csvFileUrl = csvFileUrl {
                            self.openCsvImport(url: csvFileUrl)
                        }
                    }
                }
            } catch MigrationError.incompatibleStore {
                DispatchQueue.main.async {
                    self.storeMigrationFailed = true
                    self.presentIncompatibleDataAlert()
                }
            } catch {
                fatalError(error.localizedDescription)
            }
        }

        // If there was a QuickAction or URL-open, it is handled here, so prevent another handler from being called
        return quickAction == nil && csvFileUrl == nil
    }

    func presentIncompatibleDataAlert() {
        guard let mostRecentWorkingVersion = UserSettings.mostRecentWorkingVersion.value else { fatalError("No recorded previously working version") }

        #if RELEASE
        // This is a common error during development, but shouldn't occur in production
        guard mostRecentWorkingVersion != BuildInfo.appVersion else { fatalError("Migration error thrown for store of same version.") }
        #endif

        guard window!.rootViewController!.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Incompatible Data", message: """
            The data on this device is not compatible with this version of Reading List.

            You previously had version \(mostRecentWorkingVersion), but now have version \(BuildInfo.appVersion). \
            You will need to install \(mostRecentWorkingVersion) again to be able to access your data.
            """, preferredStyle: .alert)

        #if DEBUG
        alert.addAction(UIAlertAction(title: "Delete Store", style: .destructive) { _ in
            NSPersistentStoreCoordinator().destroyAndDeleteStore(at: URL.applicationSupport.appendingPathComponent(PersistentStoreManager.storeFileName))
            fatalError("Store destroyed; app restart required.")
        })
        #endif

        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        window!.rootViewController!.present(alert, animated: true)
    }

    func setupSvProgressHud() {
        // Prepare the progress display style. Switched to dark in 1.4 due to a bug in the display of light style
        SVProgressHUD.setDefaultStyle(.dark)
        SVProgressHUD.setDefaultAnimationType(.native)
        SVProgressHUD.setDefaultMaskType(.clear)
        SVProgressHUD.setMinimumDismissTimeInterval(2)
    }

    func completeStoreTransactions() {
        // Apple recommends to register a transaction observer as soon as the app starts.
        SwiftyStoreKit.completeTransactions(atomically: true) { purchases in
            purchases.filter {
                ($0.transaction.transactionState == .purchased || $0.transaction.transactionState == .restored) && $0.needsFinishTransaction
            }.forEach {
                SwiftyStoreKit.finishTransaction($0.transaction)
            }
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        #if DEBUG
            if DebugSettings.quickActionSimulation == .barcodeScan {
                performQuickAction(.scanBarcode)
            } else if DebugSettings.quickActionSimulation == .searchOnline {
                performQuickAction(.searchOnline)
            }
        #endif
        UserEngagement.onAppOpen()

        if storeMigrationFailed {
            presentIncompatibleDataAlert()
        }
    }

    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        performQuickAction(QuickAction(rawValue: shortcutItem.type)!)
        completionHandler(true)
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplicationOpenURLOptionsKey: Any] = [:]) -> Bool {
        openCsvImport(url: url)
        return true
    }

    func openCsvImport(url: URL) {
        UserEngagement.logEvent(.openCsvInApp)
        tabBarController.selectedTab = .settings

        let settingsSplitView = tabBarController.selectedSplitViewController!
        let navController = settingsSplitView.masterNavigationController
        navController.dismiss(animated: false)

        // FUTURE: The pop was preventing the segue from occurring. We can end up with a taller
        // than usual navigation stack. Looking for a way to pop and then push in quick succession.
        navController.viewControllers.first!.performSegue(withIdentifier: "settingsData", sender: url)
    }

    func performQuickAction(_ action: QuickAction) {
        func presentFromToRead(_ viewController: UIViewController) {
            // All quick actions are presented from the To Read tab
            tabBarController.selectedTab = .toRead

            // Dismiss any modal views before presenting
            let navController = tabBarController.selectedSplitViewController!.masterNavigationController
            navController.dismissAndPopToRoot()
            navController.viewControllers.first!.present(viewController, animated: true, completion: nil)
        }

        switch action {
        case .scanBarcode:
            UserEngagement.logEvent(.scanBarcodeQuickAction)
            presentFromToRead(Storyboard.ScanBarcode.rootAsFormSheet())
        case .searchOnline:
            UserEngagement.logEvent(.searchOnlineQuickAction)
            presentFromToRead(Storyboard.SearchOnline.rootAsFormSheet())
        }
    }

    func monitorThemeSetting() {
        NotificationCenter.default.addObserver(self, selector: #selector(initialiseTheme), name: Notification.Name.ThemeSettingChanged, object: nil)
    }

    @objc func initialiseTheme() {
        let theme = UserSettings.theme.value
        UIApplication.shared.statusBarStyle = theme.statusBarStyle
        theme.configureForms()
    }
}

extension AppDelegate:GIDSignInDelegate {
    func sign(_ signIn: GIDSignIn!, didSignInFor user: GIDGoogleUser!, withError error: Error!) {
        if error != nil {
            print("Error! \(error!.localizedDescription)")
        }
        else {
            print("Signed in succesfully")
            GoogleDriveBackup.driveService = GTLRDriveService()
            GoogleDriveBackup.driveService!.authorizer = user.authentication.fetcherAuthorizer()
            //let name = NSNotification.Name("signedInG")
            //NotificationCenter.default.post(name: name, object: nil)
        }
    }
}

enum QuickAction: String {
    case scanBarcode = "com.andrewbennet.books.ScanBarcode"
    case searchOnline = "com.andrewbennet.books.SearchBooks"
}

