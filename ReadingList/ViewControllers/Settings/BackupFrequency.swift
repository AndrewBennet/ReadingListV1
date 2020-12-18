import UIKit
import PersistedPropertyWrapper

class BackupFrequency: UITableViewController {

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return BackupFrequencyPeriod.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BasicCell", for: indexPath)
        cell.defaultInitialise(withTheme: GeneralSettings.theme)
        guard let label = cell.textLabel else { preconditionFailure("Missing cell text label") }
        let backupFrequencyPeriod = BackupFrequencyPeriod.allCases[indexPath.row]
        label.text = backupFrequencyPeriod.description
        cell.accessoryType = backupFrequencyPeriod == AutoBackupManager.shared.backupFrequency ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        AutoBackupManager.shared.backupFrequency = BackupFrequencyPeriod.allCases[indexPath.row]
        if #available(iOS 13.0, *) {
            AutoBackupManager.shared.scheduleBackup()
        }
        tableView.reloadData()
        navigationController?.popViewController(animated: true)
    }
}

extension BackupFrequencyPeriod: CustomStringConvertible {
    var description: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .off: return "Off"
        }
    }
}