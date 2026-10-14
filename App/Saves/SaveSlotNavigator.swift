enum SaveSlotAction: Equatable {
    case save, load, overwrite, delete
}

struct SaveSlotConfirmation: Equatable {
    let action: SaveSlotAction
    let slot: Int
    var confirmFocused = false
}

enum SaveSlotCommand: Equatable {
    case save(Int), load(Int), overwrite(Int), delete(Int), close
}

struct SaveSlotNavigator: Equatable {
    var row = 0
    var column = 0
    var confirmation: SaveSlotConfirmation?

    static func actions(occupied: Bool) -> [SaveSlotAction] {
        occupied ? [.load, .overwrite, .delete] : [.save]
    }

    mutating func reset(occupied: [Bool], preferEmpty: Bool) {
        confirmation = nil
        row = 0
        if occupied.count >= 3 {
            row = (0..<3).first(where: { preferEmpty ? !occupied[$0] : occupied[$0] }) ?? 0
        }
        column = 0
    }

    mutating func handle(_ pressed: Set<PadInput>, occupied: [Bool]) -> SaveSlotCommand? {
        if confirmation != nil {
            let navigationPresses = [.dpadLeft, .dpadRight, .dpadUp, .dpadDown].filter(pressed.contains).count
            if !navigationPresses.isMultiple(of: 2) {
                confirmation?.confirmFocused.toggle()
            }
            if !pressed.isDisjoint(with: [.east, .select, .home]) {
                cancelConfirmation()
            } else if !pressed.isDisjoint(with: [.south, .start]) {
                if confirmation?.confirmFocused == true { return confirm() }
                cancelConfirmation()
            }
            return nil
        }

        if pressed.contains(.dpadUp) { row = max(row - 1, 0); clampColumn(occupied: occupied) }
        if pressed.contains(.dpadDown) { row = min(row + 1, 2); clampColumn(occupied: occupied) }
        if pressed.contains(.dpadLeft) { column = max(column - 1, 0) }
        if pressed.contains(.dpadRight) { column = min(column + 1, Self.actions(occupied: isOccupied(row, occupied: occupied)).count - 1) }
        if !pressed.isDisjoint(with: [.south, .start]) {
            let actions = Self.actions(occupied: isOccupied(row, occupied: occupied))
            if actions.indices.contains(column) { return activate(row: row, action: actions[column], occupied: occupied) }
        }
        if !pressed.isDisjoint(with: [.east, .select, .home]) { return .close }
        return nil
    }

    mutating func activate(row: Int, action: SaveSlotAction, occupied: [Bool]) -> SaveSlotCommand? {
        guard (0..<3).contains(row), occupied.indices.contains(row) else { return nil }
        let isOccupied = occupied[row]
        self.row = row
        switch action {
        case .save:
            if isOccupied {
                column = 1
                confirmation = SaveSlotConfirmation(action: .overwrite, slot: row + 1)
                return nil
            }
            column = 0
            return .save(row + 1)
        case .load, .overwrite, .delete:
            guard isOccupied else { return nil }
            column = Self.actions(occupied: true).firstIndex(of: action) ?? 0
            confirmation = SaveSlotConfirmation(action: action, slot: row + 1)
            return nil
        }
    }

    mutating func confirm() -> SaveSlotCommand? {
        guard let confirmation else { return nil }
        self.confirmation = nil
        switch confirmation.action {
        case .save: return .save(confirmation.slot)
        case .load: return .load(confirmation.slot)
        case .overwrite: return .overwrite(confirmation.slot)
        case .delete: return .delete(confirmation.slot)
        }
    }

    mutating func cancelConfirmation() {
        confirmation = nil
    }

    private mutating func clampColumn(occupied: [Bool]) {
        column = min(column, Self.actions(occupied: isOccupied(row, occupied: occupied)).count - 1)
    }

    private func isOccupied(_ row: Int, occupied: [Bool]) -> Bool {
        occupied.indices.contains(row) && occupied[row]
    }
}
