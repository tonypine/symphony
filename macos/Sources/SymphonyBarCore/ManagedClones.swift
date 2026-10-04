import Foundation

/// Why Symphony's clone of a repo wasn't deleted.
public enum ManagedCloneError: LocalizedError, Equatable {
    /// The path isn't inside the folder Symphony keeps its clones under.
    case outsideRoot(path: String, root: String)

    public var errorDescription: String? {
        switch self {
        case let .outsideRoot(path, root):
            return "\(path) isn't inside Symphony's clones folder \(root), so the app didn't delete it."
        }
    }
}

/// Symphony's own clones of `workspace.source` repos, kept under `workspaces.clones_root`, and when the app may
/// delete one. Kept free of AppKit so it can be unit tested.
public enum ManagedClones {
    public static let buttonTitle = "Remove Clone…"
    public static let confirmTitle = "Remove Clone"
    /// Where Symphony keeps its clones when `workspaces.clones_root` is unset.
    public static let defaultRoot = "~/.local/share/symphony/repos"

    /// Whether the app may delete a repo's clone now.
    public enum Removal: Equatable {
        /// Nothing uses the clone at `path`.
        case allowed(path: String)
        /// The reason the app shows instead.
        case blocked(String)

        /// The clone to delete, nil while it is blocked.
        public var path: String? {
            guard case let .allowed(path) = self else { return nil }
            return path
        }
    }

    /// The folder Symphony keeps its clones under: `workspaces.clones_root` in `yaml`, with `~` expanded and a
    /// relative path taken from the folder of the `symphony.yml` at `configPath`, or the default.
    public static func root(in yaml: String, configPath: String) -> URL {
        var path = defaultRoot
        if let value = try? clonesRoot(in: yaml), !value.isEmpty { path = value }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = ((configPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// The folder Symphony clones `owner/repo` into under `root`.
    public static func clonePath(root: URL, gitHub: String) -> URL {
        root.appendingPathComponent(gitHub.lowercased()).standardizedFileURL
    }

    /// Whether the clone of `gitHub` can be deleted, for Symphony's `status` and the last repos poll. A Symphony
    /// that answers must list its running agents, and none may work in a worktree of the clone: any repo with the
    /// same source shares it. Symphony's own clone path is used when it reports one.
    public static func removal(
        gitHub: String,
        root: URL,
        status: SymphonyStatus,
        poll: ReposPoll?,
        isDirectory: (String) -> Bool = ManagedClones.isDirectory
    ) -> Removal {
        var path = clonePath(root: root, gitHub: gitHub).path
        switch status {
        case .starting:
            return .blocked("Symphony is starting and may be cloning the repo. Try again once it runs.")
        case .error:
            return .blocked("Symphony isn't answering, so the app can't tell whether an agent uses the clone.")
        case .stopped:
            break
        case .running, .paused:
            guard case let .repos(repos, warning)? = poll else {
                return .blocked(poll == nil
                    ? "Checking whether an agent uses the clone…"
                    : "Symphony didn't list its running agents, so the app can't tell whether one uses the clone.")
            }
            guard warning == nil else {
                return .blocked("Symphony couldn't list its running agents, so the app can't tell whether one uses the clone.")
            }
            let sharing = repos.filter { repo in
                guard case let .managed(other, _, _) = repo.source else { return false }
                return other.lowercased() == gitHub.lowercased()
            }
            let runs = sharing.flatMap(\.worktrees).map(\.issueIdentifier)
            guard runs.isEmpty else {
                return .blocked("\(runs.joined(separator: ", ")) \(runs.count == 1 ? "runs" : "run") in a worktree of "
                    + "this clone. Remove it once \(runs.count == 1 ? "that run finishes" : "they finish").")
            }
            for repo in sharing {
                if case let .managed(_, clonePath?, _) = repo.source { path = clonePath }
            }
        }
        guard isInside(path, root: root) else {
            return .blocked(ManagedCloneError.outsideRoot(path: path, root: root.path).localizedDescription)
        }
        guard isDirectory((path as NSString).appendingPathComponent(".git")) else {
            return .blocked("No clone at \((path as NSString).abbreviatingWithTildeInPath) yet: Symphony clones the "
                + "repo when it starts or on its next dispatch.")
        }
        return .allowed(path: path)
    }

    /// The alert asking before deleting the clone of `gitHub` at `path`, which the repo `key` uses.
    public static func question(key: String, gitHub: String, path: String) -> (title: String, message: String) {
        (
            "Remove Symphony's clone of \(gitHub)?",
            "This deletes \((path as NSString).abbreviatingWithTildeInPath). Your own checkouts aren't touched, and \(key) "
                + "stays connected: Symphony clones it again when it starts or on its next dispatch."
        )
    }

    public static func removedMessage(key: String, path: String) -> String {
        "Removed Symphony's clone of \(key) at \((path as NSString).abbreviatingWithTildeInPath)."
    }

    /// Deletes the clone at `path` after checking, with symlinks resolved, that it is inside `root` and isn't
    /// `root` itself. Throws `ManagedCloneError.outsideRoot` and deletes nothing otherwise.
    public static func remove(_ path: String, root: URL, fileManager: FileManager = .default) throws {
        guard isInside(path, root: root) else { throw ManagedCloneError.outsideRoot(path: path, root: root.path) }
        try fileManager.removeItem(at: resolved(path))
    }

    /// True when `path` is strictly inside `root` once both are standardized and their symlinks resolved.
    public static func isInside(_ path: String, root: URL) -> Bool {
        let base = resolved(root.path).pathComponents
        let target = resolved(path).pathComponents
        return path.hasPrefix("/") && target.count > base.count && Array(target.prefix(base.count)) == base
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func resolved(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The `workspaces.clones_root` value without quotes, nil when it isn't set.
    private static func clonesRoot(in yaml: String) throws -> String? {
        let document = Document(yaml)
        guard let workspaces = document.child("workspaces", in: document.all) else { return nil }
        guard let key = document.child("clones_root", in: try document.block(of: workspaces)) else { return nil }
        var value = ValueLine(key.rest).value
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value == "~" || value == "null" ? nil : value
    }
}

extension SymphonyConfigFile {
    /// The folder Symphony keeps its clones under, as `ManagedClones.root` reads it from this file.
    public func readClonesRoot() throws -> URL {
        ManagedClones.root(in: try read(), configPath: path)
    }
}
