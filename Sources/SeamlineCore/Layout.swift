import Foundation

public struct Cell: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }

    public func step(_ edge: Edge) -> Cell {
        switch edge {
        case .left: return Cell(x: x - 1, y: y)
        case .right: return Cell(x: x + 1, y: y)
        case .top: return Cell(x: x, y: y - 1)
        case .bottom: return Cell(x: x, y: y + 1)
        }
    }
}

/// Which Mac sits next to which. A grid keeps neighbours unambiguous: one Mac per side.
public struct Layout: Codable, Equatable, Sendable {
    public private(set) var cells: [String: Cell]

    public init(cells: [String: Cell] = [:]) { self.cells = cells }

    public func cell(of id: String) -> Cell? { cells[id] }

    public func machine(at cell: Cell) -> String? {
        cells.first { $0.value == cell }?.key
    }

    public func neighbor(of id: String, toward edge: Edge) -> String? {
        guard let c = cells[id] else { return nil }
        return machine(at: c.step(edge))
    }

    /// Sides of `id` that touch another Mac, used to draw the crossing seams.
    public func connectedEdges(of id: String) -> [Edge] {
        Edge.allCases.filter { neighbor(of: id, toward: $0) != nil }
    }

    /// Moves `id` to `cell`. A Mac already there trades places, so a drop never fails.
    public mutating func place(_ id: String, at cell: Cell) {
        if let occupant = machine(at: cell), occupant != id {
            if let previous = cells[id] {
                cells[occupant] = previous
            } else {
                cells[occupant] = nil
            }
        }
        cells[id] = cell
    }

    public mutating func remove(_ id: String) { cells[id] = nil }

    /// Free cells touching the arrangement, plus the ones Macs already occupy, for drop targets.
    public func dropTargets(for id: String) -> Set<Cell> {
        let others = cells.filter { $0.key != id }
        var targets = Set(others.values)
        for c in others.values {
            for edge in Edge.allCases { targets.insert(c.step(edge)) }
        }
        if let own = cells[id] { targets.insert(own) }
        return targets
    }

    /// Shifts every cell so the arrangement starts at (0, 0), which keeps drawing math simple.
    public mutating func normalize() {
        guard let minX = cells.values.map(\.x).min(), let minY = cells.values.map(\.y).min() else { return }
        cells = cells.mapValues { Cell(x: $0.x - minX, y: $0.y - minY) }
    }
}
