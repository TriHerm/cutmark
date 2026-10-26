import Foundation

/// Keep redo separate from the persisted, replayable draft. A failed disk write can discard a
/// proposed history together with its proposed draft, leaving both controls on the saved state.
struct TimelineUndoHistory {
    private(set) var redoActions: [EditTimelineDraft.Action] = []

    mutating func apply(_ action: EditTimelineDraft.Action, to draft: inout EditTimelineDraft) -> Bool {
        guard draft.apply(action) else { return false }
        redoActions.removeAll()
        return true
    }

    mutating func undo(_ draft: inout EditTimelineDraft) -> Bool {
        guard let action = draft.actions.last, draft.undoLast() else { return false }
        redoActions.append(action)
        return true
    }

    mutating func redo(_ draft: inout EditTimelineDraft) -> Bool {
        guard let action = redoActions.last, draft.apply(action) else { return false }
        redoActions.removeLast()
        return true
    }

    static func title(_ action: EditTimelineDraft.Action) -> String {
        let clip = "section \(action.index + 1)"
        switch action.op {
        case "split": return "Split \(clip)"
        case "remove": return "Removed \(clip)"
        case "move": return "Moved \(clip)"
        case "duplicate": return "Duplicated \(clip)"
        case "trim", "extend": return "Trimmed \(clip)"
        default: return "Edited \(clip)"
        }
    }
}
