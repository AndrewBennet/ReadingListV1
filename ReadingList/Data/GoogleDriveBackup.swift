//__COPYRIGHT__

import Foundation
import GoogleSignIn
import CoreData
import GoogleAPIClientForREST

///Class will take data to backup to Google Drive. If offline, save file and try later
public class GoogleDriveBackup {
    public static let DriveBackup: GoogleDriveBackup = GoogleDriveBackup()
    public static var driveService: GTLRDriveService?
    private var currentlyBackingUp = false
    @objc public func dataUpdated() {
        if GoogleDriveBackup.driveService?.authorizer != nil {
            print("Should resave data")
            if !currentlyBackingUp {
                backupBooks()
            }
        } else {
            print("Not signed in, dont save")
        }
    }
    public func setup() {
        //NotificationCenter.default.addObserver(self, selector: #selector(GoogleDriveBackup.dataUpdated), name: Notification.Name.NSManagedObjectContextObjectsDidChange, object: nil)
        //NotificationCenter.default.addObserver(self, selector: #selector(GoogleDriveBackup.dataUpdated), name: Notification.Name.NSManagedObjectContextDidSave, object: nil)
    }
    /// Call to backup books in the background thread
    public func backupBooks() {
        if GoogleDriveBackup.driveService?.authorizer == nil {
            print("Authorizer not set")
            return
        }
        currentlyBackingUp = true
        DispatchQueue.global(qos: .background).async {
            self.exportData { url in
                var booksData = Data()
                do {
                    try booksData = Data(contentsOf: url)
                    print("Got data from books url")
                } catch let error {
                    print("error parsing with error \(error.localizedDescription)")
                    return
                }
                self.getFolderId { folderId in
                    if folderId == nil {
                        // Unable to create folder
                        return
                    }
                    self.currentBackupId(folderId: folderId!) { id in
                        if id == nil {
                            //First backup, create file
                            self.uploadFile(fileData: booksData, parent: folderId!)
                        } else {
                            //Update exisitng backup
                            self.updateFile(fileData: booksData, fileId: id!)
                        }
                    }
                }
            }
        }
    }
    private func exportData(completion: @escaping (URL) -> Void) {
        UserEngagement.logEvent(.csvExport)
        let listNames = List.names(fromContext: PersistentStoreManager.container.viewContext)
        let temporaryFilePath = URL.temporary(fileWithName: "Reading List-\(UIDevice.current.name)-\(Date().string(withDateFormat: "yyyy-MM-dd hh-mm")).csv")
        let exporter = CsvExporter(filePath: temporaryFilePath, csvExport: BookCSVExport.build(withLists: listNames))
        let exportAll = NSManagedObject.fetchRequest(Book.self)
        exportAll.sortDescriptors = [
            NSSortDescriptor(\Book.readState),
            NSSortDescriptor(\Book.sort),
            NSSortDescriptor(\Book.startedReading),
            NSSortDescriptor(\Book.finishedReading)]
        exportAll.relationshipKeyPathsForPrefetching = [#keyPath(Book.subjects), #keyPath(Book.authors), #keyPath(Book.lists)]
        exportAll.returnsObjectsAsFaults = false
        exportAll.fetchBatchSize = 50
        let context = PersistentStoreManager.container.viewContext.childContext(concurrencyType: .privateQueueConcurrencyType, autoMerge: false)
        context.perform {
            let results = try! context.fetch(exportAll)
            exporter.addData(results)
            completion(exporter.filePath)
        }
    }
    func getFolderId(completion: @escaping (_ fileId: String?) -> Void) {
        let query = GTLRDriveQuery_FilesList.query()
        query.q = "mimeType='application/vnd.google-apps.folder' and name = 'Book-List_Backup' and trashed = false"
        query.spaces = "drive"
        print("Excecuting query")
        GoogleDriveBackup.driveService?.executeQuery(query) { _, files, error in
            if error == nil {
                guard let myFiles = files as? GTLRDrive_FileList
                    else {
                        print("Couldnt parse, returning")
                        return
                }
                if myFiles.files?.count ?? 0 == 0 {
                    //need to add folder
                    print("No folder yet, adding one")
                    self.addFolder(completion: completion)
                } else {
                    print("Folder already exists, returning current one")
                    completion(myFiles.files![0].identifier!)
                }
            }
        }
    }
    func addFolder(completion: @escaping (_ fileId: String?) -> Void) {
        let folder = GTLRDrive_File()
        folder.name = "Book-List_Backup"
        folder.mimeType = "application/vnd.google-apps.folder"
        let createQuery = GTLRDriveQuery_FilesCreate.query(withObject: folder, uploadParameters: nil)
        createQuery.fields = "id"
        if GoogleDriveBackup.driveService != nil {
            GoogleDriveBackup.driveService?.executeQuery(createQuery) { _, file, error in
                if error == nil {
                    if let myFile = file as? GTLRDrive_File {
                        completion(myFile.identifier!)
                    } else {
                        print("Couldnt parse")
                        completion(nil)
                    }
                } else {
                    print("Error")
                    completion(nil)
                }
            }
        } else {
            print("Drive services is nil")
        }
    }
    func currentBackupId(folderId: String, completion: @escaping (_ id: String?) -> Void) {
        let query = GTLRDriveQuery_FilesList.query()
        print("Query is \("mimeType='text/plain' and name = 'ReadingList-Backup-\(removeApostrophes(input: UIDevice.current.name))' and '\(folderId)' in parents and trashed = false")")
        query.q = "mimeType='text/plain' and name = 'ReadingList-Backup-\(removeApostrophes(input: UIDevice.current.name))' and '\(folderId)' in parents and trashed = false"
        query.spaces = "drive"
        print("Excecuting query")
        GoogleDriveBackup.driveService?.executeQuery(query) { _, files, error in
            if error == nil {
                guard let myFiles = files as? GTLRDrive_FileList
                    else {
                        print("Couldnt parse, returning")
                        return
                }
                if myFiles.files?.count ?? 0 == 0 {
                    //need to add folder
                    print("File does not exist")
                    completion(nil)
                } else {
                    print("File already exists, returning current one")
                    completion(myFiles.files![0].identifier!)
                }
            } else {
                completion(nil)
            }
        }
    }
    func uploadFile(fileData: Data, parent: String) {
        let file = GTLRDrive_File()
        file.name = "ReadingList-Backup-\(removeApostrophes(input: UIDevice.current.name))"
        //to place in folder
        file.parents = [parent]
        let uploadParams = GTLRUploadParameters(data: fileData, mimeType: "text/plain")
        uploadParams.shouldUploadWithSingleRequest = true
        let query = GTLRDriveQuery_FilesCreate.query(withObject: file, uploadParameters: uploadParams)
        query.fields = "id"
        GoogleDriveBackup.driveService!.executeQuery(query) { ticket, _, error in
            if error == nil {
                print("File is \(ticket)")
                self.currentlyBackingUp = false
            }
        }
    }
    func updateFile(fileData: Data, fileId: String) {
        let file = GTLRDrive_File()
        file.originalFilename = "ReadingList-Backup-\(removeApostrophes(input: UIDevice.current.name))"
        file.name = "ReadingList-Backup-\(removeApostrophes(input: UIDevice.current.name))"
        let uploadParams = GTLRUploadParameters(data: fileData, mimeType: "text/plain")
        uploadParams.shouldUploadWithSingleRequest = true
        let query = GTLRDriveQuery_FilesUpdate.query(withObject: file, fileId: fileId, uploadParameters: uploadParams)
        GoogleDriveBackup.driveService!.executeQuery(query) { ticket, _, error in
            if error == nil {
                print("File is \(ticket)")
                self.currentlyBackingUp = false
            }
        }
    }
    private func removeApostrophes(input: String) -> String {
        return input.replacingOccurrences(of: "'", with: "")
    }
}
