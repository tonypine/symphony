import Foundation

/// One node of a tree list (TP-1507): an item and the items under it, each drawn one step in.
public struct TreeNode<ID: Hashable>: Equatable {
    public var id: ID
    public var children: [TreeNode]

    public init(_ id: ID, children: [TreeNode] = []) {
        self.id = id
        self.children = children
    }

    /// How many nodes are under it, at any depth.
    public var descendants: Int { children.reduce(0) { $0 + 1 + $1.descendants } }
}

/// What a line of a tree list is: a node's row, or the pill that stands for the rows folded under a node.
public enum TreeKey<ID: Hashable>: Hashable {
    case row(ID)
    /// The pill under `ID`, the last node shown of its chain.
    case more(ID)
}

/// One line of a tree list as it is drawn, top to bottom.
public struct TreeLine<ID: Hashable>: Equatable, Identifiable {
    public var key: TreeKey<ID>
    /// 0 for a root.
    public var depth: Int
    /// The root its chain hangs from: opening or closing a fold acts on the whole chain.
    public var root: ID
    /// For the pill, how many rows it stands for; 0 for a row.
    public var hidden: Int
    /// For each level from 1 to `depth`, whether its rail runs on past this line to the next one.
    public var railsContinue: [Bool]

    public var id: TreeKey<ID> { key }
}

/// The lines of a tree list, and how the arrow keys move through them and open and close its folds.
public enum TreeLines {
    /// Every line of `nodes`, in order. Past `foldDepth` (nil: never) a chain whose root is not in `opened` shows a
    /// pill under its last row shown, counting the rows under that row.
    public static func lines<ID: Hashable>(_ nodes: [TreeNode<ID>], foldDepth: Int? = nil, opened: Set<ID> = []) -> [TreeLine<ID>] {
        var lines: [TreeLine<ID>] = []
        func walk(_ node: TreeNode<ID>, depth: Int, root: ID) {
            lines.append(TreeLine(key: .row(node.id), depth: depth, root: root, hidden: 0, railsContinue: []))
            guard !node.children.isEmpty else { return }
            if let foldDepth, depth >= foldDepth, !opened.contains(root) {
                lines.append(TreeLine(key: .more(node.id), depth: depth + 1, root: root, hidden: node.descendants, railsContinue: []))
                return
            }
            for child in node.children { walk(child, depth: depth + 1, root: root) }
        }
        for node in nodes { walk(node, depth: 0, root: node.id) }
        for index in lines.indices {
            let next = index + 1 < lines.count ? lines[index + 1].depth : 0
            lines[index].railsContinue = lines[index].depth == 0 ? [] : (1 ... lines[index].depth).map { next >= $0 }
        }
        return lines
    }

    /// The line `by` lines from `key` (−1 up, 1 down), staying on the first or the last; the first line from none.
    public static func move<ID: Hashable>(from key: TreeKey<ID>?, by offset: Int, in lines: [TreeLine<ID>]) -> TreeKey<ID>? {
        guard !lines.isEmpty else { return nil }
        guard let key, let index = lines.firstIndex(where: { $0.key == key }) else { return lines[0].key }
        return lines[min(max(index + offset, 0), lines.count - 1)].key
    }

    /// The Right arrow on `key`: the pill, or the row the pill hangs under, opens its chain. Nil when nothing opens.
    public static func open<ID: Hashable>(_ key: TreeKey<ID>?, in lines: [TreeLine<ID>], opened: Set<ID>) -> Set<ID>? {
        guard let key, let index = lines.firstIndex(where: { $0.key == key }) else { return nil }
        let line = lines[index]
        let pill: TreeLine<ID>? = if case .more = line.key { line } else if index + 1 < lines.count, case .more = lines[index + 1].key {
            lines[index + 1]
        } else { nil }
        guard let pill, !opened.contains(pill.root) else { return nil }
        return opened.union([pill.root])
    }

    /// The Left arrow on `key` in an opened chain: it folds again, and a row it hides gives the selection to the pill
    /// that now stands for it, the one under its ancestor at `foldDepth`. Nil when `key` is in no opened chain.
    public static func close<ID: Hashable>(
        _ key: TreeKey<ID>?, in nodes: [TreeNode<ID>], foldDepth: Int, opened: Set<ID>
    ) -> (opened: Set<ID>, selection: TreeKey<ID>?)? {
        let current = lines(nodes, foldDepth: foldDepth, opened: opened)
        guard let key, let index = current.firstIndex(where: { $0.key == key }), opened.contains(current[index].root) else {
            return nil
        }
        let folded = opened.subtracting([current[index].root])
        let after = lines(nodes, foldDepth: foldDepth, opened: folded)
        if after.contains(where: { $0.key == key }) { return (folded, key) }
        // A hidden row sits under its ancestor at `foldDepth`, and that ancestor's pill is the one that stands for it.
        guard let fold = current[..<index].last(where: { $0.depth == foldDepth }), case let .row(id) = fold.key else {
            return (folded, nil)
        }
        return (folded, .more(id))
    }
}
