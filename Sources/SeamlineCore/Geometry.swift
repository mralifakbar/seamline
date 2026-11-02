import Foundation

/// Global display coordinates in points, origin at the top-left of the main display, y grows down (CoreGraphics convention).
public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Rect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func union(_ r: Rect) -> Rect {
        let nx = min(minX, r.minX), ny = min(minY, r.minY)
        return Rect(x: nx, y: ny, width: max(maxX, r.maxX) - nx, height: max(maxY, r.maxY) - ny)
    }

    /// Clamps to the last addressable point, one point inside the far edges.
    public func clamp(_ p: Point) -> Point {
        Point(x: min(max(p.x, minX), maxX - 1), y: min(max(p.y, minY), maxY - 1))
    }

    func distanceSquared(to p: Point) -> Double {
        let dx = max(minX - p.x, 0, p.x - (maxX - 1))
        let dy = max(minY - p.y, 0, p.y - (maxY - 1))
        return dx * dx + dy * dy
    }
}

public enum Edge: UInt8, CaseIterable, Codable, Sendable {
    case left, right, top, bottom

    public var opposite: Edge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    public var isHorizontal: Bool { self == .left || self == .right }
}

/// The arrangement of one Mac's displays, and the edge math that runs on every pointer event.
public struct ScreenSpace: Equatable, Sendable {
    public let displays: [Rect]
    public let bounds: Rect

    public init(displays: [Rect]) {
        let list = displays.isEmpty ? [Rect(x: 0, y: 0, width: 1440, height: 900)] : displays
        self.displays = list
        bounds = list.dropFirst().reduce(list[0]) { $0.union($1) }
    }

    public func displayIndex(containing p: Point) -> Int? {
        displays.firstIndex { $0.contains(p) }
    }

    public func nearestDisplayIndex(to p: Point) -> Int {
        if let i = displayIndex(containing: p) { return i }
        var best = 0, bestDistance = Double.infinity
        for (i, d) in displays.enumerated() {
            let dist = d.distanceSquared(to: p)
            if dist < bestDistance { best = i; bestDistance = dist }
        }
        return best
    }

    /// True when nothing lies beyond `edge` of display `index` at the given position along that edge.
    public func isOuter(_ edge: Edge, ofDisplay index: Int, at p: Point) -> Bool {
        let d = displays[index]
        let probe: Point
        switch edge {
        case .left: probe = Point(x: d.minX - 0.5, y: p.y)
        case .right: probe = Point(x: d.maxX + 0.5, y: p.y)
        case .top: probe = Point(x: p.x, y: d.minY - 0.5)
        case .bottom: probe = Point(x: p.x, y: d.maxY + 0.5)
        }
        return displayIndex(containing: probe) == nil
    }

    /// Position along an edge of the whole space, from 0 (top or left) to 1.
    public func fraction(of p: Point, along edge: Edge) -> Double {
        let value = edge.isHorizontal ? (p.y - bounds.minY) / bounds.height : (p.x - bounds.minX) / bounds.width
        return min(max(value, 0), 1)
    }

    /// Detects a real cursor resting on an outer display edge and pushing outward.
    /// `cornerGuard` keeps hot corners usable by ignoring the ends of each edge.
    public func pushedEdge(at p: Point, delta: Point, cornerGuard: Double) -> Edge? {
        guard let i = displayIndex(containing: p) else { return nil }
        let d = displays[i]
        let alongX = p.x - d.minX >= cornerGuard && d.maxX - p.x >= cornerGuard
        let alongY = p.y - d.minY >= cornerGuard && d.maxY - p.y >= cornerGuard
        if delta.x > 0, p.x >= d.maxX - 1, alongY, isOuter(.right, ofDisplay: i, at: p) { return .right }
        if delta.x < 0, p.x <= d.minX, alongY, isOuter(.left, ofDisplay: i, at: p) { return .left }
        if delta.y > 0, p.y >= d.maxY - 1, alongX, isOuter(.bottom, ofDisplay: i, at: p) { return .bottom }
        if delta.y < 0, p.y <= d.minY, alongX, isOuter(.top, ofDisplay: i, at: p) { return .top }
        return nil
    }

    /// Where the pointer appears when it arrives through `edge` at `fraction` along it.
    public func entryPoint(through edge: Edge, fraction: Double) -> Point {
        let f = min(max(fraction, 0), 1)
        if edge.isHorizontal {
            let y = bounds.minY + f * (bounds.height - 1)
            let candidates = displays.filter { y >= $0.minY && y < $0.maxY }
            let pool = candidates.isEmpty ? displays : candidates
            if edge == .left {
                let d = pool.min { $0.minX < $1.minX }!
                return d.clamp(Point(x: d.minX, y: y))
            } else {
                let d = pool.max { $0.maxX < $1.maxX }!
                return d.clamp(Point(x: d.maxX - 1, y: y))
            }
        } else {
            let x = bounds.minX + f * (bounds.width - 1)
            let candidates = displays.filter { x >= $0.minX && x < $0.maxX }
            let pool = candidates.isEmpty ? displays : candidates
            if edge == .top {
                let d = pool.min { $0.minY < $1.minY }!
                return d.clamp(Point(x: x, y: d.minY))
            } else {
                let d = pool.max { $0.maxY < $1.maxY }!
                return d.clamp(Point(x: x, y: d.maxY - 1))
            }
        }
    }
}

/// Accumulates outward push at an edge, so a pointer brushing an edge does not jump machines.
public struct EdgeResistance: Sendable {
    public var threshold: Double
    private var edge: Edge?
    private var accumulated: Double = 0

    public init(threshold: Double) { self.threshold = threshold }

    /// Returns true once enough outward travel has built up against the same edge.
    public mutating func push(_ pushed: Edge?, amount: Double) -> Bool {
        guard let pushed else { reset(); return false }
        if pushed != edge { edge = pushed; accumulated = 0 }
        accumulated += abs(amount)
        if accumulated >= threshold { reset(); return true }
        return false
    }

    public mutating func reset() { edge = nil; accumulated = 0 }
}

/// The host's model of the pointer while it is on another Mac. Deltas in, absolute positions out.
public struct VirtualCursor: Sendable {
    public enum Outcome: Equatable {
        case moved(Point)
        case exited(Edge, fraction: Double)
    }

    public let space: ScreenSpace
    public private(set) var position: Point
    private var display: Int
    private var resistance: EdgeResistance

    public init(space: ScreenSpace, position: Point, resistance: Double) {
        self.space = space
        let index = space.nearestDisplayIndex(to: position)
        self.position = space.displays[index].clamp(position)
        display = index
        self.resistance = EdgeResistance(threshold: resistance)
    }

    public mutating func move(dx: Double, dy: Double, allowExit: Bool) -> Outcome {
        let target = Point(x: position.x + dx, y: position.y + dy)
        if let i = space.displayIndex(containing: target) {
            display = i
            position = target
            resistance.reset()
            return .moved(target)
        }

        let d = space.displays[display]
        let clamped = d.clamp(target)
        var pushed: Edge?
        var overshoot = 0.0
        func consider(_ edge: Edge, _ amount: Double) {
            if amount > overshoot, space.isOuter(edge, ofDisplay: display, at: clamped) {
                pushed = edge; overshoot = amount
            }
        }
        if target.x >= d.maxX { consider(.right, dx) }
        if target.x < d.minX { consider(.left, -dx) }
        if target.y >= d.maxY { consider(.bottom, dy) }
        if target.y < d.minY { consider(.top, -dy) }

        // Sliding along a seam between two displays can land in the neighbour on one axis.
        if pushed == nil {
            for probe in [Point(x: target.x, y: position.y), Point(x: position.x, y: target.y)] {
                if let i = space.displayIndex(containing: probe) {
                    display = i
                    position = probe
                    return .moved(probe)
                }
            }
        }

        position = clamped
        if allowExit, let edge = pushed, resistance.push(edge, amount: overshoot) {
            return .exited(edge, fraction: space.fraction(of: clamped, along: edge))
        }
        return .moved(clamped)
    }
}
