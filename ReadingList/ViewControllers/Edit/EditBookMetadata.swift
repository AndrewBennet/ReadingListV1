import Foundation
import Eureka
import ImageRow
import UIKit
import CoreData
import SVProgressHUD
import ReadingList_Foundation

class EditBookMetadata: FormViewController {

    private var editBookContext = PersistentStoreManager.container.viewContext.childContext()
    private var book: Book!
    private var isAddingNewBook: Bool!

    convenience init(bookToEditID: NSManagedObjectID) {
        self.init()
        self.isAddingNewBook = false
        self.book = (editBookContext.object(with: bookToEditID) as! Book)
    }

    convenience init(bookToCreateReadState: BookReadState) {
        self.init()
        self.isAddingNewBook = true
        self.book = Book(context: editBookContext)
        if bookToCreateReadState == .reading {
            book.setReading(started: Date())
        }
        if bookToCreateReadState == .finished {
            book.setFinished(started: Date(), finished: Date())
        }
        self.book.manualBookId = UUID().uuidString
    }

    let isbnRowKey = "isbn"
    let deleteRowKey = "delete"
    let updateFromGoogleRowKey = "updateFromGoogle"

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Workaround bug https://stackoverflow.com/a/47839657/5513562
        if #available(iOS 11.2, *) {
            if #available(iOS 11.3, *) { /* Bug resolved in iOS 11.3 */ } else {
                navigationController!.navigationBar.tintAdjustmentMode = .normal
                navigationController!.navigationBar.tintAdjustmentMode = .automatic
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureNavigationItem()

        // Watch the book object for changes and validate the form
        NotificationCenter.default.addObserver(self, selector: #selector(validate), name: .NSManagedObjectContextObjectsDidChange, object: editBookContext)

        // Just to prevent having to reference `self` in the onChange handlers...
        let book = self.book!

        form +++ Section(header: "Title", footer: "")
            <<< TextRow {
                $0.cell.textField.autocapitalizationType = .words
                $0.placeholder = "Title"
                $0.value = book.title
                $0.onChange { book.title = $0.value ?? "" }
            }

            +++ AuthorSection(book: book, navigationController: navigationController!)

            +++ Section(header: "Additional Information", footer: "Note: if provided, ISBN-13 must be a valid, 13 digit ISBN.")
            <<< Int32Row {
                $0.title = "Page Count"
                $0.value = book.pageCount
                $0.onChange {
                    guard let pageCount = $0.value else { book.pageCount = nil; return }
                    guard pageCount >= 0 else { book.pageCount = nil; return }
                    book.pageCount = pageCount
                }
            }
            <<< PickerInlineRow<Language> {
                $0.title = "Language"
                if let code = book.languageCode {
                    $0.value = Language.byIsoCode[code]
                }
                $0.options = Language.all
                $0.onChange {
                    book.languageCode = $0.value?.isoCode
                }
            }
            <<< DateRow {
                $0.title = "Publication Date"
                $0.value = book.publicationDate
                $0.onChange { book.publicationDate = $0.value }
            }
            <<< ButtonRow {
                $0.title = "Subjects"
                $0.cellStyle = .value1
                $0.cellUpdate { cell, _ in
                    cell.textLabel!.textAlignment = .left
                    cell.textLabel!.textColor = UserDefaults.standard[.theme].titleTextColor
                    cell.accessoryType = .disclosureIndicator
                    cell.detailTextLabel?.text = book.subjects.map { $0.name }.sorted().joined(separator: ", ")
                }
                $0.onCellSelection { [unowned self] _, row in
                    self.navigationController!.pushViewController(EditBookSubjectsForm(book: book, sender: row), animated: true)
                }
            }
            <<< ImageRow {
                $0.title = "Cover Image"
                $0.cell.height = { 100 }
                $0.value = UIImage(optionalData: book.coverImage)
                $0.onChange { book.coverImage = $0.value == nil ? nil : $0.value!.jpegData(compressionQuality: 0.7) }
            }
            <<< Int64Row(isbnRowKey) {
                $0.title = "ISBN-13"
                $0.value = book.isbn13
                $0.formatter = nil
                $0.onChange {
                    book.isbn13 = $0.value
                }
            }

            +++ Section(header: "Description", footer: "")
            <<< TextAreaRow {
                $0.placeholder = "Description"
                $0.value = book.bookDescription
                $0.onChange { book.bookDescription = $0.value }
                $0.cellSetup { [unowned self] cell, _ in
                    cell.height = { (self.view.frame.height / 3) - 10 }
                }
            }

            // Update and delete buttons
            +++ Section()
            <<< ButtonRow(updateFromGoogleRowKey) {
                $0.title = "Update from Google Books"
                $0.hidden = Condition(booleanLiteral: isAddingNewBook || book.googleBooksId == nil)
                $0.onCellSelection(updateFromGooglePressed(cell:row:))
            }
            <<< ButtonRow(deleteRowKey) {
                $0.title = "Delete"
                $0.cellSetup { cell, _ in cell.tintColor = .red }
                $0.onCellSelection { [unowned self] _, _ in
                    self.deletePressed()
                }
                $0.hidden = Condition(booleanLiteral: isAddingNewBook)
            }

        #if DEBUG
        form +++ Section("Debug")
            <<< Int32Row {
                $0.title = "Sort"
                $0.value = book.sort
                $0.onChange {
                    book.sort = $0.value
                }
            }
            <<< LabelRow {
                $0.title = "Manual Book ID"
                $0.value = book.manualBookId
            }
            <<< LabelRow {
                $0.title = "Google Books ID"
                $0.value = book.googleBooksId
            }
        #endif

        // Validate on start
        validate()

        monitorThemeSetting()
    }

    func configureNavigationItem() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelPressed))
        if isAddingNewBook {
            navigationItem.title = "Add Book"
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Next", style: .plain, target: self, action: #selector(presentEditReadingState))
        } else {
            navigationItem.title = "Edit Book"
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(donePressed))
        }
    }

    func deletePressed() {
        guard !isAddingNewBook else { return }

        let confirmDeleteAlert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        confirmDeleteAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        confirmDeleteAlert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            // Delete the book, log the event, and dismiss this modal view
            self.editBookContext.performAndSave {
                self.book.delete()
            }
            UserEngagement.logEvent(.deleteBook)
            self.dismiss(animated: true)
        })

        self.present(confirmDeleteAlert, animated: true, completion: nil)
    }

    func updateFromGooglePressed(cell: ButtonCellOf<String>, row: _ButtonRowOf<String>) {
        let areYouSure = UIAlertController(title: "Confirm Update", message: "Updating from Google Books will overwrite any book metadata changes you have made manually. Are you sure you wish to proceed?", preferredStyle: .alert)
        areYouSure.addAction(UIAlertAction(title: "Update", style: .default, handler: updateBookFromGoogleHandler))
        areYouSure.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        present(areYouSure, animated: true)
    }

    func updateBookFromGoogleHandler(_: UIAlertAction) {
        guard let googleBooksId = book.googleBooksId else { return }
        SVProgressHUD.show(withStatus: "Downloading...")

        GoogleBooks.fetch(googleBooksId: googleBooksId)
            .always(on: .main) {
                SVProgressHUD.dismiss()
            }
            .catch(on: .main) { _ in
                SVProgressHUD.showError(withStatus: "Could not update book details")
            }
            .then(on: .main, updateBookFromGoogle)
    }

    func updateBookFromGoogle(fetchResult: FetchResult) {
        book.populate(fromFetchResult: fetchResult)
        editBookContext.saveIfChanged()
        dismiss(animated: true) {
            // FUTURE: Would be nice to display whether any changes were made
            SVProgressHUD.showInfo(withStatus: "Book updated")
        }
    }

    @objc func validate() {
        navigationItem.rightBarButtonItem!.isEnabled = book.isValidForUpdate()
    }

    @objc func cancelPressed() {
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
        editBookContext.saveIfChanged()
        dismiss(animated: true) {
            UserEngagement.onReviewTrigger()
        }
    }

    @objc func presentEditReadingState() {
        guard book.isValidForUpdate() else { return }
        navigationController!.pushViewController(EditBookReadState(newUnsavedBook: book, scratchpadContext: editBookContext), animated: true)
    }
}

class AuthorSection: MultivaluedSection {

    // This form is only presented by a metadata form, so does not need to maintain
    // a strong reference to the book's object context
    var book: Book!

    var isInitialising = true
    weak var navigationController: UINavigationController!

    required init(book: Book, navigationController: UINavigationController) {
        super.init(multivaluedOptions: [.Insert, .Delete, .Reorder], header: "Authors", footer: "Note: at least one author is required") {
            for author in book.authors {
                $0 <<< AuthorRow(author: author)
            }
            $0.addButtonProvider = { _ in
                ButtonRow {
                    $0.title = "Add Author"
                    $0.cellUpdate { cell, _ in
                        cell.textLabel!.textAlignment = .left
                    }
                }
            }
        }
        self.navigationController = navigationController
        self.multivaluedRowToInsertAt = { [unowned self] _ in
            let authorRow = AuthorRow()
            self.navigationController.pushViewController(AddAuthorForm(authorRow), animated: true)
            return authorRow
        }
        self.book = book
        isInitialising = false
    }

    required init() {
        super.init(multivaluedOptions: [], header: "", footer: "") { _ in }
    }

    required init(multivaluedOptions: MultivaluedOptions, header: String, footer: String, _ initializer: (MultivaluedSection) -> Void) {
        super.init(multivaluedOptions: multivaluedOptions, header: header, footer: footer, initializer)
    }

    required init<S>(_ elements: S) where S: Sequence, S.Element == BaseRow {
        super.init(elements)
    }

    func rebuildAuthors() {
        // It's a bit tricky with Eureka to manage an ordered set: the reordering comes through rowsHaveBeenRemoved
        // and rowsHaveBeenAdded, so we can't delete books on removal, since they might need to come back.
        // Instead, we take the brute force approach of deleting all authors and rebuilding the set each time
        // something changes. We can check whether there are any meaningful differences before we embark on this though.
        let newAuthors: [(String, String?)] = self.compactMap {
            guard let authorRow = $0 as? AuthorRow else { return nil }
            guard let lastName = authorRow.lastName else { return nil }
            return (lastName, authorRow.firstNames)
        }
        if book.authors.map({ ($0.lastName, $0.firstNames) }).elementsEqual(newAuthors, by: { $0.0 == $1.0 && $0.1 == $1.1 }) {
            return
        }
        book.authors = newAuthors.map { Author(lastName: $0.0, firstNames: $0.1) }
    }

    override func rowsHaveBeenRemoved(_ rows: [BaseRow], at: IndexSet) {
        super.rowsHaveBeenRemoved(rows, at: at)
        guard !isInitialising else { return }
        rebuildAuthors()
    }

    override func rowsHaveBeenAdded(_ rows: [BaseRow], at: IndexSet) {
        super.rowsHaveBeenAdded(rows, at: at)
        guard !isInitialising else { return }
        rebuildAuthors()
    }
}

final class AuthorRow: _LabelRow, RowType {
    var lastName: String?
    var firstNames: String?

    convenience init(tag: String? = nil, author: Author? = nil) {
        self.init(tag: tag)
        lastName = author?.lastName
        firstNames = author?.firstNames
        reload()
    }

    required init(tag: String?) {
        super.init(tag: tag)
        cellStyle = .value1

        cellUpdate { [unowned self] cell, _ in
            cell.textLabel!.textAlignment = .left
            cell.textLabel!.text = [self.firstNames, self.lastName].compactMap { $0 }.joined(separator: " ")
        }
    }
}

class AddAuthorForm: FormViewController {

    weak var presentingRow: AuthorRow!

    convenience init(_ row: AuthorRow) {
        self.init()
        self.presentingRow = row
    }

    let lastNameRow = "lastName"
    let firstNamesRow = "firstNames"

    override func viewDidLoad() {
        super.viewDidLoad()

        form +++ Section(header: "Author Name", footer: "")
            <<< TextRow(firstNamesRow) {
                $0.placeholder = "First Name(s)"
                $0.cell.textField.autocapitalizationType = .words
            }
            <<< TextRow(lastNameRow) {
                $0.placeholder = "Last Name"
                $0.cell.textField.autocapitalizationType = .words
            }

        monitorThemeSetting()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        // The removal of the presenting row should be at the point of disappear, since viewWillDisappear
        // is called when a right-swipe is started - the user could reverse and bring this view back
        let lastName = (form.rowBy(tag: lastNameRow) as! _TextRow).value
        if lastName?.isEmptyOrWhitespace != false {
            guard let index = presentingRow.indexPath?.row else { return }
            presentingRow.section!.remove(at: index)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if let lastName = (form.rowBy(tag: lastNameRow) as! _TextRow).value, !lastName.isEmptyOrWhitespace {
            presentingRow.lastName = lastName
            presentingRow.firstNames = (form.rowBy(tag: firstNamesRow) as! _TextRow).value
            presentingRow.reload()
            (presentingRow.section as! AuthorSection).rebuildAuthors()
        }
    }
}

class EditBookSubjectsForm: FormViewController {

    convenience init(book: Book, sender: _ButtonRowOf<String>) {
        self.init()
        self.book = book
        self.sendingRow = sender
    }

    weak var sendingRow: _ButtonRowOf<String>!

    // This form is only presented by a metadata form, so does not need to maintain
    // a strong reference to the book's object context
    var book: Book!

    override func viewDidLoad() {
        super.viewDidLoad()

        form +++ MultivaluedSection(multivaluedOptions: [.Insert, .Delete], header: "Subjects", footer: "Add subjects to categorise this book") {
            $0.addButtonProvider = { _ in
                ButtonRow {
                    $0.title = "Add New Subject"
                    $0.cellUpdate { cell, _ in
                        cell.textLabel?.textAlignment = .left
                    }
                }
            }
            $0.multivaluedRowToInsertAt = { _ in
                TextRow {
                    $0.placeholder = "Subject"
                    $0.cell.textField.autocapitalizationType = .words
                }
            }
            for subject in book.subjects.sorted(by: { $0.name < $1.name }) {
                $0 <<< TextRow {
                    $0.value = subject.name
                    $0.cell.textField.autocapitalizationType = .words
                }
            }
        }

        monitorThemeSetting()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        let subjectNames = form.rows.compactMap { ($0 as? TextRow)?.value?.trimming().nilIfWhitespace() }
        if book.subjects.map({ $0.name }) != subjectNames {
            book.subjects = Set(subjectNames.map { Subject.getOrCreate(inContext: book.managedObjectContext!, withName: $0) })
        }
        sendingRow.reload()
    }
}
