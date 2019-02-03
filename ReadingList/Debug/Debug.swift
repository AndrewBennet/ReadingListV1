#if DEBUG

import Foundation
import CoreData
import SimulatorStatusMagic
import ReadingList_Foundation

extension QuickAction: UserSettingType {}

extension UserSettingsCollection {
    static let showSortNumber = UserSetting<Bool>("showSortNumber", defaultValue: false)
    static let quickActionSimulation = UserSetting<QuickAction?>("shortcut-type-simulation")
}

class Debug {

    private static let screenshotsCommand = "--UITests_Screenshots"

    static func initialiseSettings() {
        if CommandLine.arguments.contains("--reset") {
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
            NSPersistentStoreCoordinator().destroyAndDeleteStore(at: URL.applicationSupport.appendingPathComponent(PersistentStoreManager.storeFileName))
        }
        if CommandLine.arguments.contains(screenshotsCommand) {
            SDStatusBarManager.sharedInstance().enableOverrides()
        }
    }

    static func initialiseData() {
        if CommandLine.arguments.contains("--UITests_PopulateData") {
            loadData {
                if CommandLine.arguments.contains("--UITests_DeleteLists") {
                    PersistentStoreManager.delete(type: List.self)
                    NotificationCenter.default.post(name: .PersistentStoreBatchOperationOccurred, object: nil)
                }
            }
        }
    }

    static func loadData(_ completion: (() -> Void)?) {
        let csvPath = Bundle.main.url(forResource: "examplebooks", withExtension: "csv")!
        BookCSVImporter(includeImages: CommandLine.arguments.contains(screenshotsCommand)).startImport(fromFileAt: csvPath) { error, _ in
            guard error == nil else { preconditionFailure("Error in CSV file") }
            DispatchQueue.main.async {
                completion?()
            }
        }
    }
}

#endif
