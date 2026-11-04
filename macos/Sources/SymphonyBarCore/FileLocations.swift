import Foundation

/// A file in a ticket's workspace that a question's text points the Director at (TP-1386): an absolute path or a
/// `file://` link, such as the HTML catalog a design review asks them to open. Symphony lets one through only under
/// its workspace root, in a question's why, its question and an option's effect
/// (`SymphonyElixir.HumanActions.PlainWords`); the Inbox and the ticket page show it as a link.
public struct FileLocation: Equatable {
    /// What a click on the link does.
    public enum Opening: Equatable {
        /// An HTML file opens in the default browser.
        case browser
        /// Any other file, or a folder, is shown in Finder.
        case finder
    }

    /// Where the location sits in the text, in UTF-16 units, without the punctuation that ends a sentence around it.
    public var range: NSRange
    /// The file, as a `file://` URL.
    public var url: URL

    public init(range: NSRange, url: URL) {
        self.range = range
        self.url = url
    }

    public var opening: Opening {
        ["html", "htm"].contains(url.pathExtension.lowercased()) ? .browser : .finder
    }

    /// Opens the location as `opening` says, through `workspace`.
    public func open(in workspace: FileLocationWorkspace) {
        switch opening {
        case .browser: workspace.openInBrowser(url)
        case .finder: workspace.revealInFinder(url)
        }
    }
}

/// What opens a file location: the Mac's `NSWorkspace` in the app, a recorder in tests.
public protocol FileLocationWorkspace {
    func openInBrowser(_ url: URL)
    func revealInFinder(_ url: URL)
}

/// Finds the file locations in a text the Inbox shows.
public enum FileLocations {
    /// A `file://` link with no host (or `localhost`), or a word that starts with a single slash. The slash can't
    /// follow a letter, digit or path character, so "and/or", "TP-1382/index.html" and "~/notes" are no location.
    static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w/:.~%-])(?:file://(?:localhost)?/[^\s<>"'`]*|/[^\s<>"'`/][^\s<>"'`]*)"#,
        options: [.caseInsensitive]
    )
    /// The punctuation that ends a clause or closes a bracket after a location: "Open /x/index.html." links
    /// "/x/index.html".
    static let trailing = CharacterSet(charactersIn: ".,;:!?)]}>\u{201D}\u{2019}\u{2026}")

    /// The file locations in `text`, in reading order.
    public static func find(in text: String) -> [FileLocation] {
        let string = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            var word = string.substring(with: match.range)
            while let last = word.unicodeScalars.last, trailing.contains(last) {
                word.unicodeScalars.removeLast()
            }
            guard let url = url(of: word) else { return nil }
            return FileLocation(range: NSRange(location: match.range.location, length: (word as NSString).length), url: url)
        }
    }

    private static func url(of word: String) -> URL? {
        guard word.lowercased().hasPrefix("file:") else {
            return word.count > 1 ? URL(fileURLWithPath: word) : nil
        }
        guard let url = URL(string: word), url.isFileURL, url.path.count > 1 else { return nil }
        return url
    }
}
