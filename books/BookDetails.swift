//
//  BookDetailsViewController.swift
//  books
//
//  Created by Andrew Bennet on 09/11/2015.
//  Copyright © 2015 Andrew Bennet. All rights reserved.
//

import UIKit
import CoreData
import CoreSpotlight

class BookDetails: UIViewController {
    
    var book: Book?
    
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var authorsLabel: UILabel!
    @IBOutlet weak var descriptionLabel: UILabel!
    @IBOutlet weak var imageView: UIImageView!
    
    override func viewDidLoad() {
        // Keep an eye on changes to the book store
        appDelegate.booksStore.addSaveObserver(self, selector: #selector(bookChanged(_:)))
        updateUi()
    }
    
    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool {
        return book != nil
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        let navController = segue.destination as! UINavigationController
        if let editBookController = navController.viewControllers.first as? EditBook {
            editBookController.bookToEdit = self.book
        }
        else if let changeReadState = navController.viewControllers.first as? EditReadState {
            changeReadState.bookToEdit = self.book
        }
    }
    
    @objc private func bookChanged(_ notification: Notification) {
        guard let book = book, let userInfo = (notification as NSNotification).userInfo else { return }
        
        if let updatedObjects = userInfo[NSUpdatedObjectsKey] as? NSSet , updatedObjects.contains(book) {
            // If the book was updated, update this page
            updateUi()
        }
        else if let deletedObjects = userInfo[NSDeletedObjectsKey] as? NSSet , deletedObjects.contains(book) {
            // If the book was deleted, clear this page, and pop back if necessary
            clearUi()
            appDelegate.splitViewController.masterNavigationController.popToRootViewController(animated: false)
        }
    }
    
    private func updateUi() {
        guard let book = book else { clearUi(); return }

        titleLabel.text = book.title
        authorsLabel.text = book.authorList
        descriptionLabel.text = book.bookDescription
        imageView.image = UIImage(optionalData: book.coverImage)
    }
    
    private func clearUi() {
        titleLabel.text = nil
        descriptionLabel.text = nil
        imageView.image = nil
    }
    
    @IBAction func moreDescriptionWasPressed(_ sender: UIButton) {
        descriptionLabel.numberOfLines = 0
    }
    
    override var previewActionItems: [UIPreviewActionItem] {
        get {
            guard let book = book else { return [UIPreviewActionItem]() }
            
            func readStatePreviewAction() -> UIPreviewAction? {
                guard book.readState != .finished else { return nil }
                
                return UIPreviewAction(title: book.readState == .toRead ? "Started" : "Finished", style: .default) {_,_ in
                    book.readState = book.readState == .toRead ? .reading : .finished
                    book.setDate(Date(), forState: book.readState)
                    appDelegate.booksStore.save()
                }
            }
            
            var previewActions = [UIPreviewActionItem]()
            if let readStatePreviewAction = readStatePreviewAction() {
                previewActions.append(readStatePreviewAction)
            }
            previewActions.append(UIPreviewAction(title: "Delete", style: .destructive){_,_ in
                appDelegate.booksStore.delete(book)
            })
            
            return previewActions
        }
    }
}
