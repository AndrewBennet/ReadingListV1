import Foundation
import UIKit
import CoreData
import os.log
import ReadingList_Foundation

class UITableViewSearchableEmptyStateManager: UITableViewEmptyStateManager {

    let searchController: UISearchController
    let navigationBar: UINavigationBar?
    let navigationItem: UINavigationItem
    let initialLargeTitleDisplayMode: UINavigationItem.LargeTitleDisplayMode
    let initialPrefersLargeTitles: Bool

    let emptyStateTitleFont = UIFont.gillSans(forTextStyle: .title1)
    let emptyStateDescriptionFont = UIFont.gillSans(forTextStyle: .title2)
    let emptyStateDescriptionBoldFont = UIFont.gillSansSemiBold(forTextStyle: .title2)

    init(_ tableView: UITableView, navigationBar: UINavigationBar?, navigationItem: UINavigationItem, searchController: UISearchController) {
        self.searchController = searchController
        self.navigationBar = navigationBar
        self.navigationItem = navigationItem
        self.initialLargeTitleDisplayMode = navigationItem.largeTitleDisplayMode
        self.initialPrefersLargeTitles = navigationBar?.prefersLargeTitles ?? false
        super.init(tableView)
    }

    override func emptyStateDidChange() {
        super.emptyStateDidChange()
        if isShowingEmptyState {
            if !searchController.isActive {
                navigationItem.searchController?.searchBar.isHidden = true
                navigationItem.largeTitleDisplayMode = .never
                navigationBar?.prefersLargeTitles = false
            }
        } else {
            navigationItem.searchController?.searchBar.isHidden = false
            navigationItem.largeTitleDisplayMode = initialLargeTitleDisplayMode
            navigationBar?.prefersLargeTitles = initialPrefersLargeTitles
        }
    }

    private func attributeWithThemeColor(_ attributedString: NSAttributedString) -> NSAttributedString {
        if #available(iOS 13.0, *) {
            return attributedString
        } else {
            return attributedString.mutable().attributedWithColor(UserDefaults.standard[.theme].titleTextColor)
        }
    }

    final override func titleForEmptyState() -> NSAttributedString {
        let title: NSAttributedString
        if searchController.hasActiveSearchTerms {
            title = "🔍 No Results".attributedWithFont(emptyStateTitleFont)
        } else {
            title = titleForNonSearchEmptyState().attributedWithFont(emptyStateTitleFont)
        }

        return attributeWithThemeColor(title)
    }

    final override func textForEmptyState() -> NSAttributedString {
        let text: NSAttributedString
        if searchController.hasActiveSearchTerms {
            text = textForSearchEmptyState()
        } else {
            text = textForNonSearchEmptyState()
        }

        return attributeWithThemeColor(text)
    }

    final override func positionForEmptyState() -> EmptyStatePosition {
        if searchController.isActive {
            return .top
        } else {
            return .center
        }
    }

    func titleForNonSearchEmptyState() -> String {
        fatalError("titleForNonSearchEmptyState() not implemented")
    }

    func textForNonSearchEmptyState() -> NSAttributedString {
        fatalError("textForNonSearchEmptyState() not implemented")
    }

    func textForSearchEmptyState() -> NSAttributedString {
        fatalError("textForNonSearchEmptyState() not implemented")
    }
}
