import UIKit
import CoreData
import ReadingList_Foundation
import os.log

final class BookTable: UITableViewController { //swiftlint:disable:this type_body_length

    // The read states that this book table initially shows books for, in order that they should appear
    var readStates: [BookReadState]!

    private var dataSource: BookTableDataSourceCommon!
    private var resultsControllers: [(readState: BookReadState, controller: NSFetchedResultsController<Book>)]!
    private var searchController: UISearchController!
    private var emptyStateManager: BookTableEmptyDataSourceManager!

    private let allReadStatesSearchBarScopeIndex = 1

    override func viewDidLoad() {
        // Register the headers and cells we use for this table
        tableView.register(BookTableHeader.self)
        tableView.register(BookTableViewCell.self)

        tableView.allowsMultipleSelectionDuringEditing = true
        clearsSelectionOnViewWillAppear = false
        navigationItem.title = readStates.last!.description

        // When filtering books with the search bar, it is nice if we dismiss the keyboard when scrolling starts
        tableView.keyboardDismissMode = .onDrag

        // The search bar should have two scope buttons: one which represents the read states shown normally in this VC,
        // the other for "all books".
        searchController = UISearchController(filterPlaceholderText: "Your Library")
        searchController.searchBar.scopeButtonTitles = [readStates.map { $0.description }.joined(separator: " & "), "All"]
        searchController.searchBar.delegate = self
        searchController.searchResultsUpdater = self
        searchController.delegate = self
        navigationItem.searchController = searchController

        // Build the results controllers, and then configure their predicates. We do this in two separate functions as
        // it is a quite frequent operation that we wish to update the results controller predicates later on.
        resultsControllers = buildResultsControllers()
        configureControllersPredicates()

        // Perform the initial fetches
        for controller in resultsControllers {
            try! controller.controller.performFetch()
        }

        // The sort manager is responsible for calculating new sort indexes of items following a reordering. It would be nicer
        // to move this entirely within the data source, but that is a bit tricky since it requires a reference to the data source
        // at the point of initialization.
        let sortManager = SortManager<Book>(tableView) { [unowned self] in
            self.dataSource.object(at: $0)
        }

        // On iOS 13 we use Diffable Data Sources; on prior OSes we use the legacy data source which peforms more manual row interactions
        if #available(iOS 13.0, *) {
            dataSource = BookTableDiffableDataSource(tableView, controllers: resultsControllers.map(\.controller), sortManager: sortManager,
                                                     searchController: searchController, onContentChanged: reconfigureNavigationBarAndSectionHeaders)
        } else {
            dataSource = BookTableLegacyDataSource(tableView, controllers: resultsControllers.map(\.controller), sortManager: sortManager,
                                                   searchController: searchController, onContentChanged: reconfigureNavigationBarAndSectionHeaders)
        }

        // The empty data source manager is in charge of handling and reacting to the empty table state
        let emptyStateMode = BookTableEmptyDataSourceManager.mode(from: readStates)
        emptyStateManager = BookTableEmptyDataSourceManager(tableView: tableView, navigationBar: navigationController?.navigationBar, navigationItem: navigationItem,
                                                            searchController: searchController, mode: emptyStateMode) { [weak self] _ in
            self?.configureNavigationBarButtons()
        }
        dataSource.emptyDetectionDelegate = emptyStateManager

        // Perform the initial data source load, and then configure the navigation bar buttons, which depend on the empty state of the table
        dataSource.updateData(animate: false)
        configureNavigationBarButtons()

        monitorThemeSetting()
        super.viewDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Deselect selected rows, so they don't stay highlighted, but only when in non-split mode
        if let selectedIndexPath = self.tableView.indexPathForSelectedRow, !splitViewController!.detailIsPresented {
            self.tableView.deselectRow(at: selectedIndexPath, animated: animated)
        }
    }

    private func reconfigureNavigationBarAndSectionHeaders() {
        configureNavigationBarButtons()
        reloadHeaders()
    }

    /// Build a results controller for all read states, with "our" read states first, followed by everything else.
    private func buildResultsControllers() -> [(readState: BookReadState, controller: NSFetchedResultsController<Book>)] {
        return readStates.appendingRemaining(BookReadState.allCases).map { readState in
            let fetchRequest = NSManagedObject.fetchRequest(Book.self, batch: 25)
            fetchRequest.predicate = NSPredicate(boolean: false)
            fetchRequest.sortDescriptors = BookSort.byReadState[readState]!.bookSortDescriptors
            let controller = NSFetchedResultsController<Book>(fetchRequest: fetchRequest, managedObjectContext: PersistentStoreManager.container.viewContext,
                                                              sectionNameKeyPath: #keyPath(Book.readState), cacheName: nil)
            return (readState, controller)
        }
    }

    /// Configures the controller predicates
    private func configureControllersPredicates() {
        for (readState, controller) in resultsControllers {
            controller.fetchRequest.predicate = predicate(for: readState)
        }
    }

    /// Returns the predicate which should be currently used for the results controller predicate
    private func predicate(for readState: BookReadState) -> NSPredicate {
        // If this read state is not actually relevant, return the false predicate - we don't want any books.
        guard readStates.contains(readState) || (searchController.isActive && searchController.searchBar.selectedScopeButtonIndex == allReadStatesSearchBarScopeIndex) else {
            return NSPredicate(boolean: false)
        }

        // The base predicate just checks the read state
        let readStatePredicate = NSPredicate(format: "%K == %ld", #keyPath(Book.readState), readState.rawValue)

        // If we have a searchable search text, add this condition too.
        if let searchText = searchController.searchBar.text, searchText.isSufficientForSearch() {
            let searchPredicate = NSPredicate.wordsWithinFields(searchText, fieldNames: #keyPath(Book.title), #keyPath(Book.subtitle), #keyPath(Book.authorSort),
                                                                "ANY \(#keyPath(Book.subjects)).name")
            return NSPredicate.and([readStatePredicate, searchPredicate])
        }

        return readStatePredicate
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if traitCollection.forceTouchCapability == .available {
            registerForPreviewing(with: self, sourceView: tableView)
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section < dataSource.sectionCount() else { return nil }
        let header = tableView.dequeue(BookTableHeader.self)
        header.presenter = self
        header.onSortChanged = { [weak self] in
            guard let `self` = self else { return }

            // Results controller delegates don't seem to play nicely with changing sort descriptors. So instead, we rebuild the whole
            // set of result controllers, not forgetting to pass the new ones to the data source.
            self.resultsControllers = self.buildResultsControllers()
            self.configureControllersPredicates()
            self.dataSource.replaceControllers(self.resultsControllers.map(\.controller))

            try! self.dataSource.performFetch()
            self.dataSource.updateData(animate: true)
            UserEngagement.logEvent(.changeSortOrder)
        }
        configureHeader(header, at: section)
        return header
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)

        // The search bar should be disabled if editing: searches will clear selections in edit mode,
        // so it's probably better to just prevent searches from occuring.
        searchController.searchBar.isEnabled = !editing

        // If we have stopped editing, reset the navigation title
        if !isEditing {
            navigationItem.title = readStates.last!.description
        }

        // The naviation bar buttons and the section headers both change between edit/non-edit mode, so we need to trigger this change
        configureNavigationBarButtons()
        reloadHeaders()
    }

    private func configureNavigationBarButtons() {
        let leftButton: UIBarButtonItem?
        let rightButton: UIBarButtonItem
        if isEditing {
            // If we're editing, the right button should become an "edit action" button, but be disabled until any books are selected
            leftButton = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(toggleEditingAnimated))
            rightButton = UIBarButtonItem(image: #imageLiteral(resourceName: "MoreFilledIcon"), style: .plain, target: self, action: #selector(editActionButtonPressed(_:)))
            rightButton.isEnabled = false
        } else {
            // If we're not editing, the right button should revert back to being an Add button
            leftButton = emptyStateManager.isShowingEmptyState ? nil : UIBarButtonItem(title: "Edit", style: .plain, target: self, action: #selector(toggleEditingAnimated))
            rightButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addWasPressed(_:)))
        }

        navigationItem.leftBarButtonItem = leftButton
        navigationItem.rightBarButtonItem = rightButton
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditing {
            guard let selectedRows = tableView.indexPathsForSelectedRows else { return }
            navigationItem.rightBarButtonItem!.isEnabled = true
            navigationItem.title = "\(selectedRows.count) Selected"
        } else {
            guard let selectedCell = tableView.cellForRow(at: indexPath) else { return }
            performSegue(withIdentifier: "showDetail", sender: selectedCell)
        }
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard isEditing else { return }
        // If this deselection was deselecting the only selected row, disable the edit action button and reset the title
        if let selectedRows = tableView.indexPathsForSelectedRows, !selectedRows.isEmpty {
            navigationItem.title = "\(selectedRows.count) Selected"
        } else {
            navigationItem.rightBarButtonItem!.isEnabled = false
            navigationItem.title = readStates.last!.description
        }
    }

    @available(iOS 13.0, *)
    override func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        // This enables the two-finger drag to select multiple books at once. When the interaction begins, ensure we are in edit mode
        // so that multiple rows can be selected.
        setEditing(true, animated: true)
    }

    @available(iOS 13.0, *)
    override func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        return true
    }

    @available(iOS 13.0, *)
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let book = dataSource.object(at: indexPath)
        let previewProvider = { BookDetails.instantiate(withBook: book) }
        return UIContextMenuConfiguration(identifier: book.objectID, previewProvider: previewProvider) { _ in
            // Fist set up the set of menu items which are always returned
            var menuItems: [UIMenuElement] = [
                UIAction(title: "Update Notes", image: UIImage(systemName: "text.bubble")) { _ in
                    self.present(EditBookNotes(existingBookID: book.objectID).inNavigationController(), animated: true)
                },
                UIAction(title: "Manage Lists", image: UIImage(systemName: "tray.2")) { _ in
                    self.present(ManageLists.getAppropriateVcForManagingLists([book]), animated: true)
                },
                UIAction(title: "Edit Book", image: UIImage(systemName: "square.and.pencil")) { _ in
                    self.present(EditBookMetadata(bookToEditID: book.objectID).inNavigationController(), animated: true)
                },
                UIAction(title: "Manage Log", image: UIImage(systemName: "calendar")) { _ in
                    self.present(EditBookReadState(existingBookID: self.dataSource.object(at: indexPath).objectID).inNavigationController(), animated: true)
                },
                UIAction(title: "Delete", image: UIImage(systemName: "trash.fill"), attributes: .destructive) { _ in
                    let confirm = self.confirmDeleteAlert(indexPaths: [indexPath])
                    confirm.popoverPresentationController?.setSourceCell(atIndexPath: indexPath, inTable: tableView)
                    self.present(confirm, animated: true)
                }
            ]

            // If book ordering can be edited, then add actions to move this book to the top or bottom.
            if BookSort.byReadState[book.readState] == .custom {
                let minSort = Book.minSort(with: book.readState, from: PersistentStoreManager.container.viewContext)
                let maxSort = Book.maxSort(with: book.readState, from: PersistentStoreManager.container.viewContext)
                var moveUpOrDownActions = [UIMenuElement]()
                if let minSort = minSort, book.sort != minSort {
                    moveUpOrDownActions.append(UIAction(title: "Move To Top", image: UIImage(systemName: "arrow.up")) { _ in
                        guard let context = book.managedObjectContext else { return }
                        UserEngagement.logEvent(.moveBookToTop)
                        book.sort = minSort - 1
                        context.saveAndLogIfErrored()
                    })
                }
                if let maxSort = maxSort, book.sort != maxSort {
                    moveUpOrDownActions.append(UIAction(title: "Move To Bottom", image: UIImage(systemName: "arrow.down")) { _ in
                        guard let context = book.managedObjectContext else { return }
                        UserEngagement.logEvent(.moveBookToBottom)
                        book.sort = maxSort + 1
                        context.saveAndLogIfErrored()
                    })
                }

                // Put the actions behind a menu, if there isn't just one.
                if moveUpOrDownActions.count == 1 {
                    menuItems.insert(moveUpOrDownActions[0], at: 0)
                } else {
                    menuItems.insert(UIMenu(title: "Move...", image: UIImage(systemName: "arrow.up.arrow.down"), children: moveUpOrDownActions), at: 0)
                }
            }

            // Add an action to move the book's read state, if suitable
            if book.readState == .toRead {
                menuItems.insert(UIAction(title: "Start", image: UIImage(systemName: "play")) { _ in
                    guard let context = book.managedObjectContext else { return }
                    UserEngagement.logEvent(.transitionReadState)
                    book.setReading(started: Date())
                    book.updateSortIndex()
                    context.saveAndLogIfErrored()
                }, at: 0)
            } else if book.readState == .reading {
                menuItems.insert(UIAction(title: "Finish", image: UIImage(systemName: "checkmark")) { _ in
                    guard let context = book.managedObjectContext, let started = book.startedReading else { return }
                    UserEngagement.logEvent(.transitionReadState)
                    book.setFinished(started: started, finished: Date())
                    book.updateSortIndex()
                    context.saveAndLogIfErrored()
                }, at: 0)
            }

            return UIMenu(title: "", children: menuItems)
        }
    }

    @available(iOS 13.0, *)
    override func tableView(_ tableView: UITableView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        guard let splitViewController = splitViewController else { preconditionFailure("Missing SplitViewController") }
        guard let previewVC = animator.previewViewController else { return }

        // Called when a preview is tapped, commiting the previewed action. If we are in split mode with the book details controller
        // currently presented, we should just update the book on that controller. We don't expect the displayed controller - if
        // present - to be anything other than the BookDetails controller
        if splitViewController.detailIsPresented {
            guard let objectId = configuration.identifier as? NSManagedObjectID, let bookDetailsVc = splitViewController.displayedDetailViewController as? BookDetails else {
                return
            }
            let book = PersistentStoreManager.container.viewContext.object(with: objectId) as! Book
            bookDetailsVc.book = book

            // To ensure that the relevant row is highlighted once the detail display is updated, find its index path and select the row
            if let indexPath = dataSource.indexPath(for: book) {
                tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
            }
        } else {
            animator.addAnimations {
                self.show(previewVC, sender: self)
            }
        }
    }

    @objc private func editActionButtonPressed(_ sender: UIBarButtonItem) {
        guard let selectedRows = tableView.indexPathsForSelectedRows, !selectedRows.isEmpty else { return }
        let selectedReadStates = selectedRows.map { dataSource.readState(forSection: $0.section) }.distinct()

        let optionsAlert = UIAlertController(title: "Edit \(selectedRows.count) book\(selectedRows.count == 1 ? "" : "s")", message: nil, preferredStyle: .actionSheet)
        optionsAlert.addAction(UIAlertAction(title: "Manage Lists", style: .default) { _ in
            self.present(ManageLists.getAppropriateVcForManagingLists(selectedRows.map(self.dataSource.object)) {
                self.setEditing(false, animated: true)
                UserEngagement.logEvent(.bulkAddBookToList)
                UserEngagement.onReviewTrigger()
            }, animated: true)
        })

        if let initialSelectionReadState = selectedReadStates.first, initialSelectionReadState != .finished, selectedReadStates.count == 1 {
            let title = (initialSelectionReadState == .toRead ? "Start" : "Finish") + (selectedRows.count > 1 ? " \(selectedRows.count)" : "")
            optionsAlert.addAction(UIAlertAction(title: title, style: .default) { _ in

                // We need to manage the sort indices manually, since we will be saving the batch operation at once
                let bookSortManager = BookSortIndexManager(context: PersistentStoreManager.container.viewContext,
                                                           readState: initialSelectionReadState == .toRead ? .reading : .finished)
                for book in selectedRows.map(self.dataSource.object) {
                    if initialSelectionReadState == .toRead {
                        book.setReading(started: Date())
                    } else if let started = book.startedReading {
                        book.setFinished(started: started, finished: Date())
                    }
                    book.sort = bookSortManager.getAndIncrementSort()
                }
                PersistentStoreManager.container.viewContext.saveIfChanged()
                self.setEditing(false, animated: true)
                UserEngagement.logEvent(.bulkEditReadState)

                // Only request a review if this was a Start tap: there have been a bunch of reviews
                // on the app store which are for books, not for the app!
                if initialSelectionReadState == .toRead {
                    UserEngagement.onReviewTrigger()
                }
            })
        }

        optionsAlert.addAction(UIAlertAction(title: "Delete\(selectedRows.count > 1 ? " \(selectedRows.count)" : "")", style: .destructive) { _ in
            let confirm = self.confirmDeleteAlert(indexPaths: selectedRows) { didDelete in
                // Once the deletion has happened, switch editing mode off. Do this on the next run loop to avoid
                // messing with the row deletion animations
                guard didDelete else { return }
                DispatchQueue.main.async {
                    self.setEditing(false, animated: true)
                }
            }
            confirm.popoverPresentationController?.barButtonItem = sender
            self.present(confirm, animated: true)
        })
        optionsAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        optionsAlert.popoverPresentationController?.barButtonItem = sender

        present(optionsAlert, animated: true, completion: nil)
    }

    func simulateBookSelection(_ bookID: NSManagedObjectID, allowTableObscuring: Bool = true) {
        let book = PersistentStoreManager.container.viewContext.object(with: bookID) as! Book
        let indexPathOfSelectedBook = dataSource.indexPath(for: book)

        // If there is a row (there might not be is there is a search filtering the results, and
        // clearing the search creates animations which mess up push segues), then scroll to it.
        if let indexPathOfSelectedBook = indexPathOfSelectedBook {
            tableView.scrollToRow(at: indexPathOfSelectedBook, at: .none, animated: true)
        }

        // allowTableObscuring determines whether the book details page should actually be shown, if showing it will obscure this table
        guard let splitViewController = splitViewController else { preconditionFailure("Missing SplitViewController") }
        guard allowTableObscuring || splitViewController.isSplit else { return }

        if let indexPathOfSelectedBook = indexPathOfSelectedBook {
            tableView.selectRow(at: indexPathOfSelectedBook, animated: true, scrollPosition: .none)
        }

        // If there is a detail view presented, update the book
        if splitViewController.detailIsPresented {
            (splitViewController.displayedDetailViewController as? BookDetails)?.book = book
        } else {
            // Segue to the details view, with the cell corresponding to the book as the sender.
            performSegue(withIdentifier: "showDetail", sender: book)
        }
    }

    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool {
        // No clicking on books in edit mode, even if you force-press
        return !tableView.isEditing
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let navController = segue.destination as? UINavigationController,
            let detailsViewController = navController.topViewController as? BookDetails else { return }

        if let cell = sender as? UITableViewCell, let selectedIndex = tableView.indexPath(for: cell) {
            detailsViewController.book = self.dataSource.object(at: selectedIndex)
        } else if let book = sender as? Book {
            // When a simulated selection triggers a segue, the sender is the Book
            detailsViewController.book = book
        } else {
            assertionFailure("Unexpected sender type of segue to book details page")
        }
    }

    @IBAction private func addWasPressed(_ sender: UIBarButtonItem) {
        let optionsAlert = UIAlertController(title: "Add New Book", message: nil, preferredStyle: .actionSheet)
        optionsAlert.addAction(UIAlertAction(title: "Scan Barcode", style: .default) { _ in
            self.present(UIStoryboard.ScanBarcode.rootAsFormSheet(), animated: true, completion: nil)
        })
        optionsAlert.addAction(UIAlertAction(title: "Search Online", style: .default) { _ in
            self.present(UIStoryboard.SearchOnline.rootAsFormSheet(), animated: true, completion: nil)
        })
        optionsAlert.addAction(UIAlertAction(title: "Add Manually", style: .default) { _ in
            self.present(EditBookMetadata(bookToCreateReadState: .toRead).inThemedNavController(), animated: true, completion: nil)
        })
        optionsAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        optionsAlert.popoverPresentationController?.barButtonItem = sender

        present(optionsAlert, animated: true, completion: nil)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let moreImage, deleteImage: UIImage
        if #available(iOS 13.0, *) {
            moreImage = UIImage(systemName: "ellipsis.circle.fill")!
            deleteImage = UIImage(systemName: "trash.fill")!
        } else {
            moreImage = #imageLiteral(resourceName: "More")
            deleteImage = #imageLiteral(resourceName: "Trash")
        }
        return UISwipeActionsConfiguration(performFirstActionWithFullSwipe: false, actions: [
            UIContextualAction(style: .destructive, title: "Delete", image: deleteImage) { _, view, callback in
                let confirm = self.confirmDeleteAlert(indexPaths: [indexPath], callback: callback)
                confirm.popoverPresentationController?.sourceView = view
                self.present(confirm, animated: true, completion: nil)
            },
            UIContextualAction(style: .normal, title: "More", image: moreImage) { _, view, callback in
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                alert.addAction(UIAlertAction(title: "Manage Lists", style: .default) { _ in
                    let book = self.dataSource.object(at: indexPath)
                    self.present(ManageLists.getAppropriateVcForManagingLists([book]), animated: true)
                    callback(true)
                })
                alert.addAction(UIAlertAction(title: "Update Notes", style: .default) { _ in
                    let book = self.dataSource.object(at: indexPath)
                    self.present(EditBookNotes(existingBookID: book.objectID).inThemedNavController(), animated: true)
                    callback(true)
                })
                alert.addAction(UIAlertAction(title: "Edit Book", style: .default) { _ in
                    let book = self.dataSource.object(at: indexPath)
                    self.present(EditBookMetadata(bookToEditID: book.objectID).inThemedNavController(), animated: true)
                    callback(true)
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    callback(true)
                })
                alert.popoverPresentationController?.sourceView = view
                self.present(alert, animated: true)
            }
        ])
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let logImage: UIImage
        if #available(iOS 13.0, *) {
            logImage = UIImage(systemName: "calendar")!
        } else {
            logImage = #imageLiteral(resourceName: "Timetable")
        }
        var actions = [UIContextualAction(style: .normal, title: "Log", image: logImage) { _, _, callback in
            self.present(EditBookReadState(existingBookID: self.dataSource.object(at: indexPath).objectID).inThemedNavController(), animated: true)
            callback(true)
        }]

        let readStateOfSection = dataSource.readState(forSection: indexPath.section)
        guard readStateOfSection == .toRead || (readStateOfSection == .reading && dataSource.object(at: indexPath).startedReading! < Date()) else {
            // It is not "invalid" to have a book with a started date in the future; but it is invalid
            // to have a finish date before the start date. Therefore, hide the finish action if
            // this would be the case.
            return UISwipeActionsConfiguration(performFirstActionWithFullSwipe: false, actions: actions)
        }

        let leadingSwipeAction = UIContextualAction(style: .destructive, title: readStateOfSection == .toRead ? "Start" : "Finish") { _, _, callback in
            let book = self.dataSource.object(at: indexPath)
            if readStateOfSection == .toRead {
                book.setReading(started: Date())
                book.updateSortIndex()
            } else if let started = book.startedReading {
                book.setFinished(started: started, finished: Date())
                book.updateSortIndex()
            } else {
                assertionFailure("Unexpected read state")
            }

            book.managedObjectContext!.saveAndLogIfErrored()
            UserEngagement.logEvent(.transitionReadState)
            callback(true)

            // Workaround a strange iOS 13 quirk, where if a swipe leads to a new section appearing, setEditing(false) is not called.
            // This results in the table being unexpectedly in edit mode, and if the search conrtoller is active, it will be stuck:
            // unable to leave edit mode, and unable to select any table cells!
            if #available(iOS 13.0, *) {
                self.setEditing(false, animated: false)
            }
        }
        leadingSwipeAction.backgroundColor = readStateOfSection == .toRead ? UIColor(.buttonBlue) : UIColor(.buttonGreen)
        if #available(iOS 13.0, *) {
            leadingSwipeAction.image = UIImage(systemName: readStateOfSection == .toRead ? "play.fill" : "checkmark")
        } else {
            leadingSwipeAction.image = readStateOfSection == .toRead ? #imageLiteral(resourceName: "Play") : #imageLiteral(resourceName: "Complete")
        }
        actions.insert(leadingSwipeAction, at: 0)

        return UISwipeActionsConfiguration(actions: actions)
    }

    func confirmDeleteAlert(indexPaths: [IndexPath], callback: ((Bool) -> Void)? = nil) -> UIAlertController {
        let confirmDeleteAlert = UIAlertController(title: indexPaths.count == 1 ? "Confirm delete" : "Confirm deletion of \(indexPaths.count) books", message: nil, preferredStyle: .actionSheet)
        confirmDeleteAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            callback?(false)
        })
        confirmDeleteAlert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            indexPaths.map(self.dataSource.object).forEach { $0.delete() }
            PersistentStoreManager.container.viewContext.saveAndLogIfErrored()
            UserEngagement.logEvent(indexPaths.count > 1 ? .bulkDeleteBook : .deleteBook)
            callback?(true)
        })
        return confirmDeleteAlert
    }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        // Easy case if the sections are the same
        if sourceIndexPath.section == proposedDestinationIndexPath.section {
            return proposedDestinationIndexPath
        }

        let proposedRowIndex: Int
        if sourceIndexPath.section < proposedDestinationIndexPath.section {
            // If we are trying to move a cell into the section below this source cell's section, use the largest row value
            let sourceSectonRowCount = self.dataSource.tableView(tableView, numberOfRowsInSection: sourceIndexPath.section)
            if sourceSectonRowCount > 0 {
                proposedRowIndex = sourceSectonRowCount - 1
            } else {
                // This shouldn't happen, but be safe in case something changed in the background during the drag. We don't
                // want to propose a "-1" index, as that will cause the app to crash.
                proposedRowIndex = 0
            }
        } else {
            // Otherwise we must be trying to move a row into the section above the source section: propose a row index of 0
            proposedRowIndex = 0
        }

        return IndexPath(row: proposedRowIndex, section: sourceIndexPath.section)
    }

    private func configurePredicatesAndUpdateData() {
        configureControllersPredicates()
        try! dataSource.performFetch()
        dataSource.updateData(animate: true)
        reconfigureNavigationBarAndSectionHeaders()
    }
}

extension BookTable: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        configurePredicatesAndUpdateData()
    }
}

extension BookTable: UISearchControllerDelegate {
    func didPresentSearchController(_ searchController: UISearchController) {
        UserEngagement.logEvent(.searchLibrary)
        configurePredicatesAndUpdateData()
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        configurePredicatesAndUpdateData()
        // If we caused all data to be deleted while searching, the empty state view might now need to be a "no books" view
        // rather than a "no results" view.
        emptyStateManager.reloadEmptyStateView()
    }
}

extension BookTable: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
        UserEngagement.logEvent(.searchLibrarySwitchScope)
        configurePredicatesAndUpdateData()
    }
}

extension BookTable: HeaderConfigurable {
    func configureHeader(_ header: UITableViewHeaderFooterView, at index: Int) {
        guard let header = header as? BookTableHeader else { preconditionFailure() }
        let bookCount = dataSource.rowCount(in: index)
        let readState = dataSource.readState(forSection: index)
        header.configure(readState: readState, bookCount: bookCount, enableSort: !isEditing && !searchController.isActive)
    }
}

/// 3D touch responder for iOS 12 and below
extension BookTable: UIViewControllerPreviewingDelegate {
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, viewControllerForLocation location: CGPoint) -> UIViewController? {
        guard !tableView.isEditing else { return nil }
        guard let indexPath = tableView.indexPathForRow(at: location), let cell = tableView.cellForRow(at: indexPath) else {
            return nil
        }

        previewingContext.sourceRect = cell.frame
        return BookDetails.instantiate(withBook: dataSource.object(at: indexPath))
    }

    func previewingContext(_ previewingContext: UIViewControllerPreviewing, commit viewControllerToCommit: UIViewController) {
        show(viewControllerToCommit, sender: self)
    }
}

private extension String {
    /// Returns true if the string is non-empty and non-whitespace, and has more than 2 characters, excluding leading and trailing spaces.
    func isSufficientForSearch() -> Bool {
        return !isEmptyOrWhitespace && trimming().count >= 2
    }
}

extension Book: Sortable {
    var sortIndex: Int32 {
        get { return sort }
        set(newValue) { sort = newValue }
    }
}
