import Foundation
import CoreData

@objc(Author)
class Author: NSObject, NSCoding {

    let lastName: String
    let firstNames: String?

    init(lastName: String, firstNames: String?) {
        self.lastName = lastName
        self.firstNames = firstNames
    }

    required convenience init?(coder aDecoder: NSCoder) {
        let lastName = aDecoder.decodeObject(forKey: "lastName") as! String
        let firstNames = aDecoder.decodeObject(forKey: "firstNames") as! String?
        self.init(lastName: lastName, firstNames: firstNames)
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(self.lastName, forKey: "lastName")
        aCoder.encode(self.firstNames, forKey: "firstNames")
    }

    var fullName: String {
        guard let firstNames = firstNames else { return lastName }
        return "\(firstNames) \(lastName)"
    }

    var lastNameCommaFirstName: String {
        guard let firstNames = firstNames else { return lastName }
        return "\(lastName), \(firstNames)"
    }

    var lastNameSort: String {
        guard let firstNames = firstNames else { return lastName.sortable }
        return "\(lastName.sortable).\(firstNames.sortable)"
    }
}

extension Array where Element == Author {
    var lastNamesSort: String {
        return self.map { $0.lastNameSort }.joined(separator: "..")
    }

    var fullNames: String {
        return self.map { $0.fullName }.joined(separator: ", ")
    }
}
