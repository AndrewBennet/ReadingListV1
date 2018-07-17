import XCTest
import Foundation
import CoreData
import SwiftyJSON
@testable import Reading_List

class GoogleBooksTests: XCTestCase {

    var testContainer: NSPersistentContainer!

    override func setUp() {
        super.setUp()
        testContainer = NSPersistentContainer(inMemoryStoreWithName: "books")
        testContainer.loadPersistentStores { _, _ in }
    }

    func dataFromFile(withName name: String, ofType fileType: String) -> Data {
        let path = Bundle(for: type(of: self)).path(forResource: name, ofType: fileType)!
        return try! Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func assertBookEqualToParseResult(_ book: Book, _ parseResult: GoogleBooks.FetchResult) {
        XCTAssertEqual(book.googleBooksId, parseResult.id)
        XCTAssertEqual(book.title, parseResult.title)
        XCTAssertEqual(book.authors.count, parseResult.authors.count)
        XCTAssertEqual(book.subjects.map { $0.name }, parseResult.subjects)
        XCTAssertEqual(book.pageCount?.intValue, parseResult.pageCount)
        XCTAssertEqual(book.isbn13, parseResult.isbn13)
        XCTAssertEqual(book.bookDescription, parseResult.description)
    }

    func testGoogleBooksFetchParsing() {
        let json = JSON(dataFromFile(withName: "GoogleBooksFetchResult", ofType: "json"))

        let parseResult = GoogleBooks.Parser.parseFetchResults(json)!
        XCTAssertEqual("The Sellout", parseResult.title)
        XCTAssertEqual(1, parseResult.authors.count)
        XCTAssertEqual("Paul Beatty", parseResult.authors.first!)
        XCTAssertEqual("Fiction", parseResult.subjects[0])
        XCTAssertEqual("Satire", parseResult.subjects[1])
        XCTAssertEqual(304, parseResult.pageCount)
        XCTAssertEqual("9781786070166", parseResult.isbn13)
        XCTAssertNotNil(parseResult.description)

        let book = Book(context: testContainer.viewContext, readState: .toRead)
        book.populate(fromFetchResult: parseResult)
        XCTAssertEqual(book.authorSort, "beatty.paul")
        XCTAssertEqual(Author.authorDisplay(book.authors), "Paul Beatty")
    }

    func testGoogleBooksSearchParsing() {
        let json = JSON(dataFromFile(withName: "GoogleBooksSearchResult", ofType: "json"))

        let parseResult = GoogleBooks.Parser.parseSearchResults(json)
        // There are 3 results with no author, which we expect to not show up in the list. Hence: 37.
        XCTAssertEqual(37, parseResult.count)
        for result in parseResult {
            // Everything must have an ID, a title and at least 1 author
            XCTAssertNotNil(result.id)
            XCTAssertNotNil(result.title)
            XCTAssert(!result.title.isEmptyOrWhitespace)
            XCTAssertGreaterThan(result.authors.count, 0)
            XCTAssert(!result.authors.any { $0.isEmptyOrWhitespace })
        }

        let resultsWithIsbn = parseResult.filter { $0.isbn13 != nil }.count
        XCTAssertEqual(29, resultsWithIsbn)

        let resultsWithCover = parseResult.filter { $0.thumbnailCoverUrl != nil }.count
        XCTAssertEqual(32, resultsWithCover)
    }
}
