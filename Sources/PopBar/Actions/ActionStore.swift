import Foundation
import Combine
import SwiftUI   // for Array.move(fromOffsets:toOffset:) used by reorder

/// Owns the user's configurable actions, stored in the config file under
/// `actions`. Shared by the settings editor (CRUD) and the controller (which
/// reads the list when showing the popup).
///
/// The list lives in the SAME file as everything else on purpose: it is the part
/// of the configuration a person most wants to read, diff and copy between
/// machines, and splitting it out would mean two files to keep in step.
final class ActionStore: ObservableObject {

    private static let log = FileLog("PopBar.Actions")

    private static let path = "actions"

    @Published private(set) var actions: [PopBarActionConfig]

    init(config: ConfigStore = .shared) {
        self.config = config
        // Deliberately not `!decoded.isEmpty`: emptying the list is something a
        // person can mean, and seeding the defaults back over it would make that
        // impossible to do — the seven defaults would return on every launch.
        if let decoded = ConfigSeed.decodeActions(config.value(Self.path)) {
            actions = decoded
        } else {
            // A local, not `actions`: FileLog takes its message as an autoclosure
            // and evaluates it later, so a property read inside one reports
            // whatever it holds by then rather than now.
            let seeded = DefaultActions.seed()
            actions = seeded
            Self.log.info("no actions in the config — seeded \(seeded.count) default(s)")
            config.set(Self.path, ConfigSeed.encode(seeded))
        }

    }

    private let config: ConfigStore

    // MARK: - Two-level list

    /// The rules live in `ActionTree` (pure, no store, no disk) so they can be
    /// exercised on their own; the store only persists and publishes the result.
    typealias DropTarget = ActionTree.DropTarget

    func action(id: String) -> PopBarActionConfig? { ActionTree.action(id: id, in: actions) }
    func parentGroupID(of id: String) -> String? { ActionTree.parentGroupID(of: id, in: actions) }
    func canMove(_ id: String, to target: DropTarget) -> Bool {
        ActionTree.canMove(id, to: target, in: actions)
    }

    /// Move an action. Returns false — changing nothing — when the move isn't
    /// allowed, so the caller can leave the list alone.
    @discardableResult
    func move(_ id: String, to target: DropTarget) -> Bool {
        guard let updated = ActionTree.move(id, to: target, in: actions) else { return false }
        actions = updated
        save()
        return true
    }

    /// Remove a group but keep what was in it: the children take its place at the
    /// top level. The "delete the group, not the actions" half of the delete prompt.
    func dissolveGroup(id: String) {
        guard let updated = ActionTree.dissolve(groupID: id, in: actions) else { return }
        actions = updated
        save()
    }

    // MARK: - CRUD

    func add(_ action: PopBarActionConfig) { actions.append(action); save() }

    func update(_ action: PopBarActionConfig) {
        guard let updated = ActionTree.update(action, in: actions) else { return }
        actions = updated
        save()
    }

    /// Delete an action wherever it lives. Deleting a GROUP deletes its children
    /// with it — callers ask first (see `dissolveGroup` for the other outcome).
    func delete(id: String) {
        guard let updated = ActionTree.remove(id: id, from: actions) else { return }
        actions = updated
        save()
    }

    func resetToDefaults() { actions = DefaultActions.seed(); save() }

    // MARK: - Persistence

    /// Writes through to the config file. `ConfigStore` debounces and writes
    /// atomically, so a drag that reorders the list does not rewrite the file once
    /// per frame.
    private func save() {
        config.set(Self.path, ConfigSeed.encode(actions))
    }
}
