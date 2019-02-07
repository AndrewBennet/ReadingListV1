import Foundation
import UIKit
import Eureka
import CoreData

class EditBookNotes: FormViewController {

    private var book: Book!
    private var editContext = PersistentStoreManager.container.viewContext.childContext()

    convenience init(existingBookID: NSManagedObjectID) {
        self.init()
        self.book = (editContext.object(with: existingBookID) as! Book)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureNavigationItem()

        form +++ Section(header: "Notes", footer: "")
            <<< StarRatingRow { [unowned self] in
                $0.value = self.book.rating
                $0.onChange { [unowned self] in
                    self.book.rating = $0.value
                }
            }
            <<< TextAreaRow {
                $0.placeholder = "Add your personal notes here..."
                $0.value = book.notes
                $0.cellSetup { [unowned self] cell, _ in
                    cell.height = { (self.view.frame.height / 3) - 10 }
                }
                $0.onChange { [unowned self] cell in
                    self.book.notes = cell.value
                }
            }

        monitorThemeSetting()
    }

    func configureNavigationItem() {
        navigationItem.title = "Edit Notes"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelPressed))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(donePressed))
    }

    @objc func cancelPressed() {
        // FUTURE: Duplicates code in EditBookMetadata. Consolidate.
        guard book.changedValues().isEmpty else {
            // Confirm exit dialog
            let confirmExit = UIAlertController(title: "Unsaved changes", message: "Are you sure you want to discard your unsaved changes?", preferredStyle: .actionSheet)
            confirmExit.addAction(UIAlertAction(title: "Discard", style: .destructive) { _ in
                self.dismiss(animated: true)
            })
            confirmExit.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            present(confirmExit, animated: true, completion: nil)
            return
        }

        dismiss(animated: true, completion: nil)
    }

    @objc func donePressed() {
        guard book.isValidForUpdate() else { return }

        view.endEditing(true)
        editContext.saveIfChanged()

        presentingViewController?.dismiss(animated: true) {
            UserEngagement.onReviewTrigger()
        }
    }
}
