import Common

/// An immutable, single-linked, persistent representation of a tree node.
///
/// Unlike the mutable `TreeNode` class, a `PersistentNode` is a **value type**
/// that never changes after construction.  All structural modifications
/// (adding or removing children) produce **new values**, leaving the original
/// intact.  This is what makes the tree "persistent": old snapshots remain
/// valid and comparable without defensive copying.
///
/// This type advances the ongoing work described in
/// https://github.com/nikitabobko/AeroSpace/issues/1215 to migrate from the
/// mutable `TreeNode` class hierarchy to a fully-immutable persistent tree.
/// It is the next step after making the live tree **single-linked** (no stored
/// parent back-references) in the previous refactor.
///
/// Usage:
/// ```swift
/// // Take an immutable snapshot of a subtree
/// let snapshot = container.toPersistentNode()   // PersistentNode?
///
/// // Snapshots are Equatable – useful for change detection
/// let before = root.toPersistentNode()
/// performSomeOperation()
/// let after = root.toPersistentNode()
/// if before != after { /* tree changed */ }
///
/// // Structural modifications return new values; the original is unchanged
/// if case .tilingContainer(let c) = snapshot {
///     let newNode: PersistentNode = .window(PersistentWindow(windowId: 42))
///     let updated: PersistentContainer = c.adding(newNode, at: INDEX_BIND_LAST)
///     // `c` is still the old snapshot
/// }
/// ```
indirect enum PersistentNode: Equatable, Hashable, Sendable {
    case window(PersistentWindow)
    case tilingContainer(PersistentContainer)
}

// MARK: - Window leaf

/// An immutable snapshot of a leaf window node.
struct PersistentWindow: Equatable, Hashable, Sendable {
    /// Stable identity of the window (matches `Window.windowId`).
    let windowId: UInt32
    /// Adaptive weight of this window within its parent tiling container.
    /// Defaults to `1` for windows whose parent is not a tiling container.
    let weight: CGFloat

    init(windowId: UInt32, weight: CGFloat = 1) {
        self.windowId = windowId
        self.weight = weight
    }
}

// MARK: - Container (non-leaf)

/// An immutable snapshot of a tiling-container node.
struct PersistentContainer: Equatable, Hashable, Sendable {
    /// Ordered list of child nodes.  Order is significant (reflects tiling order).
    let children: [PersistentNode]
    let layout: Layout
    let orientation: Orientation
    /// Adaptive weight of this container within its parent tiling container.
    /// Defaults to `1` for containers whose parent is not a tiling container
    /// (e.g. the root tiling container of a workspace).
    let weight: CGFloat

    init(children: [PersistentNode], layout: Layout, orientation: Orientation, weight: CGFloat = 1) {
        self.children = children
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
    }

    /// Returns a **new** container identical to this one but with `child`
    /// inserted at `index`.  Pass `INDEX_BIND_LAST` (i.e. `-1`) to append.
    ///
    /// The original container is never modified.
    func adding(_ child: PersistentNode, at index: Int) -> PersistentContainer {
        var newChildren = children
        let insertAt = index < 0 ? newChildren.count : min(index, newChildren.count)
        newChildren.insert(child, at: insertAt)
        return PersistentContainer(children: newChildren, layout: layout, orientation: orientation, weight: weight)
    }

    /// Returns a **new** container with the child at position `index` removed,
    /// together with the removed node itself.
    ///
    /// The original container is never modified.
    func removing(at index: Int) -> (PersistentContainer, PersistentNode) {
        var newChildren = children
        let removed = newChildren.remove(at: index)
        return (PersistentContainer(children: newChildren, layout: layout, orientation: orientation, weight: weight), removed)
    }

    /// Returns a **new** container with `oldChild` replaced by `newChild`, or
    /// `nil` when `oldChild` is not a direct child of this container.
    ///
    /// The original container is never modified.
    func replacing(_ oldChild: PersistentNode, with newChild: PersistentNode) -> PersistentContainer? {
        guard let index = children.firstIndex(of: oldChild) else { return nil }
        var newChildren = children
        newChildren[index] = newChild
        return PersistentContainer(children: newChildren, layout: layout, orientation: orientation, weight: weight)
    }
}

// MARK: - Snapshot conversion

extension TreeNode {
    /// Capture the structural state of this node and its descendants as an
    /// immutable `PersistentNode` value.
    ///
    /// Returns `nil` for node types that have no `PersistentNode`
    /// representation (e.g. `Workspace` root nodes, special macOS containers).
    ///
    /// The returned value is completely independent of the live tree: further
    /// mutations to `self` or its children will *not* affect the snapshot.
    @MainActor
    func toPersistentNode() -> PersistentNode? {
        switch nodeCases {
            case .window(let w):
                return .window(PersistentWindow(windowId: w.windowId, weight: _persistentWeight(of: w)))
            case .tilingContainer(let c):
                return .tilingContainer(PersistentContainer(
                    children: c.children.compactMap { $0.toPersistentNode() },
                    layout: c.layout,
                    orientation: c.orientation,
                    weight: _persistentWeight(of: c),
                ))
            case .workspace,
                 .macosMinimizedWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer:
                return nil
        }
    }
}

/// Returns the adaptive weight of `node` within its parent tiling container,
/// or `1` when the parent is not a tiling container.
@MainActor
private func _persistentWeight(of node: TreeNode) -> CGFloat {
    guard let tilingParent = node.parent as? TilingContainer else { return 1 }
    return node.getWeight(tilingParent.orientation)
}
