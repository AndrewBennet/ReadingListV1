import CloudKit

extension Book {
    func newRecordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        let recordName = googleBooksId != nil ? "gbid:\(googleBooksId!)" : "mid:\(manualBookId!)"
        return CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    static func candidateBookForRemoteIdentifier(_ recordID: CKRecord.ID) -> NSPredicate {
        if recordID.recordName.starts(with: "gbid:") {
            return NSPredicate(format: "%K == %@", #keyPath(Book.googleBooksId), String(recordID.recordName.dropFirst(5)))
        }
        if recordID.recordName.starts(with: "mid:") {
            return NSPredicate(format: "%K == %@", #keyPath(Book.manualBookId), String(recordID.recordName.dropFirst(4)))
        }
        print("Unexpected format of remote record ID: \(recordID.recordName)")
        return NSPredicate(boolean: false)
    }

    func getValue(for ckRecordKey: CKRecordKey) -> CKRecordValue? { //swiftlint:disable:this cyclomatic_complexity
        switch ckRecordKey {
        case .title: return title as NSString
        case .googleBooksId: return googleBooksId as NSString?
        case .isbn13: return isbn13 as NSNumber?
        case .pageCount: return pageCount
        case .publicationDate: return publicationDate as NSDate?
        case .bookDescription: return bookDescription as NSString?
        case .notes: return notes as NSString?
        case .currentPage: return currentPage
        case .languageCode: return languageCode as NSString?
        case .rating: return rating
        case .sort: return sort
        case .readDates:
            switch readState {
            case .toRead: return nil
            case .reading: return [startedReading! as NSDate] as NSArray
            case .finished: return [startedReading! as NSDate, finishedReading! as NSDate] as NSArray
            }
        case .authors: return NSKeyedArchiver.archivedData(withRootObject: authors) as NSData
        case .coverImage:
            guard let coverImage = coverImage else { return nil }
            let imageFilePath = URL.temporary()
            FileManager.default.createFile(atPath: imageFilePath.path, contents: coverImage, attributes: nil)
            return CKAsset(fileURL: imageFilePath)
        }
    }

    func setValue(_ value: CKRecordValue?, for ckRecordKey: CKRecordKey) { //swiftlint:disable:this cyclomatic_complexity
        switch ckRecordKey {
        case .title: title = value as! String
        case .googleBooksId: googleBooksId = value as? String
        case .isbn13: isbn13 = value as? NSNumber
        case .pageCount: pageCount = value as? NSNumber
        case .publicationDate: publicationDate = value as? Date
        case .bookDescription: bookDescription = value as? String
        case .notes: notes = value as? String
        case .currentPage: currentPage = value as? NSNumber
        case .languageCode: languageCode = value as? String
        case .rating: rating = value as? NSNumber
        case .sort: sort = value as? NSNumber
        case .readDates:
            let datesArray = value as? [Date]
            startedReading = datesArray?[safe: 0]
            finishedReading = datesArray?[safe: 1]
            updateReadState()
        case .authors:
            setAuthors(NSKeyedUnarchiver.unarchiveObject(with: value as! Data) as! [Author])
        case .coverImage:
            guard let imageAsset = value as? CKAsset, FileManager.default.fileExists(atPath: imageAsset.fileURL.path) else {
                coverImage = nil
                return
            }
            coverImage = FileManager.default.contents(atPath: imageAsset.fileURL.path)
        }
    }

    /**
     Returns a CKRecord with every CKRecordKey set to the CKValue corresponding to the value in this book.
     */
    func recordForInsert(into zone: CKRecordZone.ID) -> CKRecord {
        let ckRecord = CKRecord(recordType: "Book", recordID: newRecordID(in: zone))
        for key in Book.CKRecordKey.allCases {
            ckRecord[key] = getValue(for: key)
        }
        return ckRecord
    }

    func recordForUpdate() -> CKRecord {
        guard let ckRecord = getSystemFieldsRecord() else { fatalError("No stored CKRecord to use for differential update") }
        for key in pendingRemoteUpdateBitmask.keys() {
            ckRecord[key] = getValue(for: key)
        }
        return ckRecord
    }

    /**
     Updates values in this book with those from the provided CKRecord. Values in this books which have a pending
     change are not updated.
    */
    func update(from ckRecord: CKRecord) {
        if let existingCKRecordSystemFields = getSystemFieldsRecord(), existingCKRecordSystemFields.recordChangeTag == ckRecord.recordChangeTag {
            print("CKRecord \(ckRecord.recordID.recordName) has same change tag as local book; skipping update")
            return
        }

        if remoteIdentifier != ckRecord.recordID.recordName {
            print("Updating remoteIdentifier from \(remoteIdentifier ?? "nil") to \(ckRecord.recordID.recordName)")
            remoteIdentifier = ckRecord.recordID.recordName
        }

        setSystemFields(ckRecord)

        // This book may have local changes which we don't want to overwrite with the values on the server.
        let pendingRemoteUpdate = pendingRemoteUpdateBitmask.keys()
        for key in CKRecordKey.allCases {
            if pendingRemoteUpdate.contains(key) {
                print("Remote value for \(key.rawValue) ignored, due to presence of a pending upstream update")
                continue
            }
            setValue(ckRecord[key], for: key)
        }
    }

    static func withRemoteIdentifier(_ id: String) -> NSPredicate {
        return NSPredicate(format: "%K == %@", #keyPath(Book.remoteIdentifier), id)
    }

    static func withRemoteIdentifiers(_ ids: [String]) -> NSPredicate {
        return NSPredicate(format: "%K in %@", #keyPath(Book.remoteIdentifier), ids)
    }
}
