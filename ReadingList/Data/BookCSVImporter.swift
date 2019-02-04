import Foundation
import CoreData
import Promises
import ReadingList_Foundation
import os.log

class BookCSVImporter {
    private let parserDelegate: BookCSVParserDelegate //swiftlint:disable:this weak_delegate
    var parser: CSVParser?

    init(includeImages: Bool = true) {
        let backgroundContext = PersistentStoreManager.container.newBackgroundContext()
        backgroundContext.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump
        parserDelegate = BookCSVParserDelegate(context: backgroundContext, includeImages: includeImages)
    }

    /**
     - Parameter completion: takes the following parameters:
        - error: if the CSV import failed irreversibly, this parameter will be non-nil
        - results: otherwise, this summary of the results of the import will be non-nil
    */
    func startImport(fromFileAt fileLocation: URL, _ completion: @escaping (CSVImportError?, BookCSVImportResults?) -> Void) {
        os_log("Beginning import from CSV file")
        parserDelegate.onCompletion = completion

        parser = CSVParser(csvFileUrl: fileLocation)
        parser!.delegate = parserDelegate
        parser!.begin()
    }
}

struct BookCSVImportResults {
    let success: Int
    let error: Int
    let duplicate: Int
}

private class BookCSVParserDelegate: CSVParserDelegate {
    private let context: NSManagedObjectContext
    private let includeImages: Bool
    private var currentSort: Int32?
    private var coverDownloadPromises = [Promise<Void>]()
    private var listMappings = [String: [(bookID: NSManagedObjectID, index: Int)]]()
    private var listNames = [String]()

    var onCompletion: ((CSVImportError?, BookCSVImportResults?) -> Void)?

    init(context: NSManagedObjectContext, includeImages: Bool = true) {
        self.context = context
        self.includeImages = includeImages
    }

    func headersRead(_ headers: [String]) -> Bool {
        if !headers.contains("Title") || !headers.contains("Authors") {
            return false
        }
        listNames = headers.filter { !BookCSVExport.headers.contains($0) }
        return true
    }

    private func createBook(_ values: [String: String]) -> Book? {
        guard let title = values["Title"] else { return nil }
        guard let authors = values["Authors"] else { return nil }
        let book = Book(context: self.context)
        book.title = title
        book.authors = createAuthors(authors)
        book.googleBooksId = values["Google Books ID"]
        book.manualBookId = book.googleBooksId == nil ? UUID().uuidString : nil
        book.isbn13 = ISBN13(values["ISBN-13"])?.int
        book.pageCount = Int32(values["Page Count"])
        book.currentPage = Int32(values["Current Page"])
        book.notes = values["Notes"]?.replacingOccurrences(of: "\r\n", with: "\n")
        book.publicationDate = Date(iso: values["Publication Date"])
        book.bookDescription = values["Description"]?.replacingOccurrences(of: "\r\n", with: "\n")
        book.startedReading = Date(iso: values["Started Reading"])
        book.finishedReading = Date(iso: values["Finished Reading"])
        book.subjects = Set(createSubjects(values["Subjects"]))
        book.rating = Int16(values["Rating"])
        book.languageCode = values["Language Code"]
        return book
    }

    private func createAuthors(_ authorString: String) -> [Author] {
        return authorString.components(separatedBy: ";").compactMap {
            guard let authorString = $0.trimming().nilIfWhitespace() else { return nil }
            if let firstCommaPos = authorString.range(of: ","), let lastName = authorString[..<firstCommaPos.lowerBound].trimming().nilIfWhitespace() {
                return Author(lastName: lastName, firstNames: authorString[firstCommaPos.upperBound...].trimming().nilIfWhitespace())
            } else {
                return Author(lastName: authorString, firstNames: nil)
            }
        }
    }

    private func createSubjects(_ subjects: String?) -> [Subject] {
        guard let subjects = subjects else { return [] }
        return subjects.components(separatedBy: ";").compactMap {
            guard let subjectString = $0.trimming().nilIfWhitespace() else { return nil }
            return Subject.getOrCreate(inContext: context, withName: subjectString)
        }
    }

    private func populateLists() {
        for listMapping in listMappings {
            let list = List.getOrCreate(fromContext: self.context, withName: listMapping.key)
            let orderedBooks = listMapping.value.sorted { $0.1 < $1.1 }
                .map { context.object(with: $0.bookID) as! Book }
                .filter { !list.books.contains($0) }
            list.addBooks(NSOrderedSet(array: orderedBooks))
        }
    }

    private func populateCover(forBook book: Book, withGoogleID googleID: String) {
        coverDownloadPromises.append(GoogleBooks.getCover(googleBooksId: googleID)
            .then { data -> Void in
                self.context.perform {
                    book.coverImage = data
                }
                return
            }
        )
    }

    func lineParseSuccess(_ values: [String: String]) {
        // FUTURE: Batch save
        context.performAndWait { [unowned self] in
            // Check for duplicates
            guard Book.get(fromContext: self.context, googleBooksId: values["Google Books ID"], isbn: values["ISBN-13"]) == nil else {
                os_log("Skipping duplicate book", type: .info)
                duplicateCount += 1; return
            }

            guard let newBook = createBook(values) else { invalidCount += 1; return }

            // FUTURE: the read state could be inferred from the dates at save time
            if newBook.finishedReading != nil {
                newBook.readState = .finished
            } else if newBook.startedReading != nil {
                newBook.readState = .reading
            } else {
                // Get the current sort value if we have not done so yet
                if currentSort == nil {
                    currentSort = Book.maxSort(fromContext: context) ?? -1
                }
                currentSort! += 1
                newBook.sort = currentSort
            }

            // If the book is not valid, delete it
            guard newBook.isValidForUpdate() else {
                invalidCount += 1
                os_log("Deleting invalid book", type: .info)
                newBook.delete()
                return
            }
            successCount += 1

            // Record the list memberships
            for listName in listNames {
                if let listPosition = Int(values[listName]) {
                    if listMappings[listName] == nil { listMappings[listName] = [] }
                    listMappings[listName]!.append((newBook.objectID, listPosition))
                }
            }

            // Supplement the book with the cover image
            if self.includeImages, let googleBookdID = newBook.googleBooksId {
                populateCover(forBook: newBook, withGoogleID: googleBookdID)
            }
        }
    }

    private var duplicateCount = 0
    private var invalidCount = 0
    private var successCount = 0

    func lineParseError() {
        invalidCount += 1
    }

    func onFailure(_ error: CSVImportError) {
        onCompletion?(error, nil)
    }

    func completion() {
        all(coverDownloadPromises)
            .always(on: .main) {
                self.context.performAndWait {
                    self.populateLists()
                    self.context.saveAndLogIfErrored()
                }
                let results = BookCSVImportResults(success: self.successCount, error: self.invalidCount, duplicate: self.duplicateCount)
                self.onCompletion?(nil, results)
            }
    }
}
