@testable import AppBundle
import XCTest

@MainActor
final class TreeNodeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // Verify the single-linked tree invariant: parent is derived from the tree
    // structure (children lists), not stored as a back-reference on the node.
    // Moving a subtree to a different parent must immediately be reflected in
    // the `.parent` computed property of every node in that subtree.
    func testSingleLinkedTree_parentReflectsChildrenList() {
        let wsA = Workspace.get(byName: "A")
        let wsB = Workspace.get(byName: "B")
        let window = TestWindow.new(id: 1, parent: wsA.rootTilingContainer)

        XCTAssertTrue(window.parent === wsA.rootTilingContainer)

        // Rebind window to the other workspace's tiling root
        window.bind(to: wsB.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)

        XCTAssertTrue(window.parent === wsB.rootTilingContainer)
        XCTAssertFalse(wsA.rootTilingContainer.children.contains(window))
        XCTAssertTrue(wsB.rootTilingContainer.children.contains(window))
    }

    func testChildParentCyclicReferenceMemoryLeak() {
        let workspace = Workspace.get(byName: name) // Don't cache root node
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        XCTAssertTrue(window.parent != nil)
        workspace.rootTilingContainer.unbindFromParent()
        XCTAssertTrue(window.parent == nil)
    }

    func testIsEffectivelyEmpty() {
        let workspace = Workspace.get(byName: name)

        XCTAssertTrue(workspace.isEffectivelyEmpty)
        weak let window: TestWindow? = .new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertNotEqual(window, nil)
        XCTAssertTrue(!workspace.isEffectivelyEmpty)
        window!.unbindFromParent()
        XCTAssertTrue(workspace.isEffectivelyEmpty)

        // Don't save to local variable
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        XCTAssertTrue(!workspace.isEffectivelyEmpty)
    }

    func testNormalizeContainers_dontRemoveRoot() {
        let workspace = Workspace.get(byName: name)
        weak let root = workspace.rootTilingContainer
        func test() {
            XCTAssertNotEqual(root, nil)
            XCTAssertTrue(root!.isEffectivelyEmpty)
            workspace.normalizeContainers()
            XCTAssertNotEqual(root, nil)
        }
        test()

        config.enableNormalizationFlattenContainers = true
        test()
    }

    func testNormalizeContainers_singleWindowChild() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(
            .h_tiles([.window(0), .window(1)]),
            workspace.rootTilingContainer.layoutDescription,
        )
    }

    func testNormalizeContainers_removeEffectivelyEmpty() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                _ = TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1)
            }
        }
        assertEquals(workspace.rootTilingContainer.children.count, 1)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.children.count, 0)
    }

    func testNormalizeContainers_flattenContainers() {
        let workspace = Workspace.get(byName: name) // Don't cache root node
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            }
        }
        workspace.normalizeContainers()
        XCTAssertTrue(workspace.rootTilingContainer.children.singleOrNil() is TilingContainer)

        config.enableNormalizationFlattenContainers = true
        workspace.normalizeContainers()
        XCTAssertTrue(workspace.rootTilingContainer.children.singleOrNil() is TestWindow)
    }

    // MARK: - PersistentNode tests

    // Two snapshots of the same live-tree state must be equal.
    func testPersistentNode_equalSnapshots() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        let snapshot1 = workspace.rootTilingContainer.toPersistentNode()
        let snapshot2 = workspace.rootTilingContainer.toPersistentNode()
        XCTAssertNotNil(snapshot1)
        XCTAssertEqual(snapshot1, snapshot2)
    }

    // After mutating the live tree the snapshot taken before the mutation must
    // be unchanged (persistence invariant).
    func testPersistentNode_snapshotUnaffectedByMutation() {
        let workspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        let before = workspace.rootTilingContainer.toPersistentNode()

        // Mutate the live tree
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        let after = workspace.rootTilingContainer.toPersistentNode()

        // The two snapshots must differ
        XCTAssertNotEqual(before, after)

        // The ORIGINAL snapshot still shows exactly the one window
        guard case .tilingContainer(let container) = before else {
            XCTFail("Expected .tilingContainer"); return
        }
        XCTAssertEqual(container.children.count, 1)
        XCTAssertEqual(container.children.first, .window(PersistentWindow(windowId: window1.windowId)))
    }

    // Unbinding a window from the live tree must be reflected in a new snapshot
    // without touching the previously taken snapshot.
    func testPersistentNode_unbindUpdatesSnapshot() {
        let workspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        let before = workspace.rootTilingContainer.toPersistentNode()

        window1.unbindFromParent()

        let after = workspace.rootTilingContainer.toPersistentNode()

        XCTAssertNotEqual(before, after)
        guard case .tilingContainer(let c) = before else {
            XCTFail("Expected .tilingContainer"); return
        }
        XCTAssertEqual(c.children.count, 2)

        guard case .tilingContainer(let cAfter) = after else {
            XCTFail("Expected .tilingContainer"); return
        }
        XCTAssertEqual(cAfter.children.count, 1)
    }

    // PersistentContainer.adding must produce a new value while leaving the
    // original untouched.
    func testPersistentContainer_addingProducesNewValue() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        guard case .tilingContainer(let original) = workspace.rootTilingContainer.toPersistentNode() else {
            XCTFail("Expected .tilingContainer"); return
        }

        let newChild = PersistentNode.window(PersistentWindow(windowId: 99))
        let updated = original.adding(newChild, at: INDEX_BIND_LAST)

        // The updated container has one more child
        XCTAssertEqual(updated.children.count, original.children.count + 1)
        XCTAssertEqual(updated.children.last, newChild)

        // The original container is unchanged
        XCTAssertEqual(original.children.count, 1)
    }

    // PersistentContainer.removing must produce a new value while leaving the
    // original untouched.
    func testPersistentContainer_removingProducesNewValue() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        guard case .tilingContainer(let original) = workspace.rootTilingContainer.toPersistentNode() else {
            XCTFail("Expected .tilingContainer"); return
        }
        XCTAssertEqual(original.children.count, 2)

        let (reduced, removed) = original.removing(at: 0)

        XCTAssertEqual(reduced.children.count, 1)
        XCTAssertEqual(removed, original.children[0])

        // The original is unchanged
        XCTAssertEqual(original.children.count, 2)
    }

    // PersistentContainer.replacing must produce a new value while leaving the
    // original untouched.
    func testPersistentContainer_replacingProducesNewValue() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        guard case .tilingContainer(let original) = workspace.rootTilingContainer.toPersistentNode() else {
            XCTFail("Expected .tilingContainer"); return
        }

        let replacement = PersistentNode.window(PersistentWindow(windowId: 99))
        let updated = original.replacing(original.children[0], with: replacement)

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.children.count, original.children.count)
        XCTAssertEqual(updated?.children[0], replacement)

        // The original is unchanged
        XCTAssertEqual(original.children[0], .window(PersistentWindow(windowId: 1)))
    }

    // Replacing a node that is NOT a child must return nil.
    func testPersistentContainer_replacingNonChild_returnsNil() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        guard case .tilingContainer(let container) = workspace.rootTilingContainer.toPersistentNode() else {
            XCTFail("Expected .tilingContainer"); return
        }

        let stranger = PersistentNode.window(PersistentWindow(windowId: 99))
        XCTAssertNil(container.replacing(stranger, with: .window(PersistentWindow(windowId: 100))))
    }

    // Workspace itself has no PersistentNode representation (it is a root, not
    // a tiling subtree node).
    func testPersistentNode_workspaceReturnsNil() {
        let workspace = Workspace.get(byName: name)
        XCTAssertNil(workspace.toPersistentNode())
    }

    // Nested containers must be captured correctly.
    func testPersistentNode_nestedContainers() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }

        guard case .tilingContainer(let root) = workspace.rootTilingContainer.toPersistentNode() else {
            XCTFail("Expected .tilingContainer"); return
        }

        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(root.children[0], .window(PersistentWindow(windowId: 1)))

        guard case .tilingContainer(let nested) = root.children[1] else {
            XCTFail("Expected nested .tilingContainer"); return
        }
        XCTAssertEqual(nested.orientation, .v)
        XCTAssertEqual(nested.children.count, 2)
        XCTAssertEqual(nested.children[0], .window(PersistentWindow(windowId: 2)))
        XCTAssertEqual(nested.children[1], .window(PersistentWindow(windowId: 3)))
    }

    // Weight of a window must be captured in the snapshot.
    func testPersistentWindow_weightIsCaptured() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        // Use distinct explicit weights so we can tell them apart.
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 2)
        TestWindow.new(id: 2, parent: root, adaptiveWeight: 3)

        guard case .tilingContainer(let snapshot) = root.toPersistentNode() else {
            XCTFail("Expected .tilingContainer"); return
        }

        guard case .window(let w1) = snapshot.children[0],
              case .window(let w2) = snapshot.children[1]
        else {
            XCTFail("Expected two window children"); return
        }
        XCTAssertEqual(w1.windowId, 1)
        XCTAssertEqual(w1.weight, 2)
        XCTAssertEqual(w2.windowId, 2)
        XCTAssertEqual(w2.weight, 3)
    }

    // Weight of a nested container must be captured in the snapshot.
    func testPersistentContainer_weightIsCaptured() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 4).apply {
            TestWindow.new(id: 1, parent: $0)
        }

        guard case .tilingContainer(let snapshot) = root.toPersistentNode(),
              case .tilingContainer(let nested) = snapshot.children[0]
        else {
            XCTFail("Expected nested .tilingContainer"); return
        }
        XCTAssertEqual(nested.weight, 4)
    }

    // PersistentContainer.adding must preserve the container's own weight.
    func testPersistentContainer_addingPreservesWeight() {
        let original = PersistentContainer(
            children: [.window(PersistentWindow(windowId: 1))],
            layout: .tiles,
            orientation: .h,
            weight: 7,
        )
        let newChild = PersistentNode.window(PersistentWindow(windowId: 2))
        let updated = original.adding(newChild, at: INDEX_BIND_LAST)
        XCTAssertEqual(updated.weight, original.weight)
        XCTAssertEqual(original.children.count, 1) // original unchanged
    }

    // PersistentContainer.removing must preserve the container's own weight.
    func testPersistentContainer_removingPreservesWeight() {
        let original = PersistentContainer(
            children: [
                .window(PersistentWindow(windowId: 1)),
                .window(PersistentWindow(windowId: 2)),
            ],
            layout: .tiles,
            orientation: .h,
            weight: 5,
        )
        let (reduced, _) = original.removing(at: 0)
        XCTAssertEqual(reduced.weight, original.weight)
        XCTAssertEqual(original.children.count, 2) // original unchanged
    }

    // PersistentContainer.replacing must preserve the container's own weight.
    func testPersistentContainer_replacingPreservesWeight() {
        let child = PersistentNode.window(PersistentWindow(windowId: 1))
        let original = PersistentContainer(
            children: [child],
            layout: .tiles,
            orientation: .h,
            weight: 6,
        )
        let replacement = PersistentNode.window(PersistentWindow(windowId: 99))
        let updated = original.replacing(child, with: replacement)
        XCTAssertEqual(updated?.weight, original.weight)
    }
}
