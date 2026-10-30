import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

typealias Vec2 = SIMD2<Double>
typealias Vec3 = SIMD3<Double>

@inline(__always) func vdot(_ a: Vec3, _ b: Vec3) -> Double { (a * b).sum() }

@inline(__always) func vcross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

@inline(__always) func vlength(_ a: Vec3) -> Double { vdot(a, a).squareRoot() }
@inline(__always) func vlength(_ a: Vec2) -> Double { (a * a).sum().squareRoot() }

/// Dense double-precision kernels. They use vDSP on Apple platforms and plain loops elsewhere,
/// so the algorithms stay testable off-device.
enum DenseKernels {
    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count)
        guard !a.isEmpty else { return 0 }
        #if canImport(Accelerate)
        var result = 0.0
        vDSP_dotprD(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
        #else
        var total = 0.0
        for i in a.indices { total += a[i] * b[i] }
        return total
        #endif
    }

    static func sum(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        #if canImport(Accelerate)
        var result = 0.0
        vDSP_sveD(a, 1, &result, vDSP_Length(a.count))
        return result
        #else
        var total = 0.0
        for value in a { total += value }
        return total
        #endif
    }

    /// y += alpha * x
    static func axpy(_ alpha: Double, _ x: [Double], into y: inout [Double]) {
        precondition(x.count == y.count)
        guard !x.isEmpty else { return }
        #if canImport(Accelerate)
        var alpha = alpha
        let count = vDSP_Length(x.count)
        x.withUnsafeBufferPointer { xp in
            y.withUnsafeMutableBufferPointer { yp in
                vDSP_vsmaD(xp.baseAddress!, 1, &alpha, yp.baseAddress!, 1, yp.baseAddress!, 1, count)
            }
        }
        #else
        for i in x.indices { y[i] += alpha * x[i] }
        #endif
    }

    /// p = s + beta * p
    static func scaledAdd(_ s: [Double], beta: Double, into p: inout [Double]) {
        precondition(s.count == p.count)
        guard !s.isEmpty else { return }
        #if canImport(Accelerate)
        var beta = beta
        let count = vDSP_Length(s.count)
        s.withUnsafeBufferPointer { sp in
            p.withUnsafeMutableBufferPointer { pp in
                vDSP_vsmaD(pp.baseAddress!, 1, &beta, sp.baseAddress!, 1, pp.baseAddress!, 1, count)
            }
        }
        #else
        for i in s.indices { p[i] = s[i] + beta * p[i] }
        #endif
    }
}

struct UnionFind {
    private var parent: [Int32]

    init(count: Int) {
        parent = (0..<count).map { Int32($0) }
    }

    mutating func find(_ element: Int) -> Int {
        var x = element
        while Int(parent[x]) != x {
            parent[x] = parent[Int(parent[x])]
            x = Int(parent[x])
        }
        return x
    }

    /// The lower index always becomes the root, which keeps numbering deterministic.
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if ra < rb { parent[rb] = Int32(ra) } else { parent[ra] = Int32(rb) }
    }
}

struct NodeHeap {
    private var items: [(priority: Double, node: Int)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(priority: Double, node: Int) {
        items.append((priority, node))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if !Self.precedes(items[child], items[parent]) { break }
            items.swapAt(parent, child)
            child = parent
        }
    }

    mutating func pop() -> (priority: Double, node: Int)? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < items.count, Self.precedes(items[left], items[smallest]) { smallest = left }
                if right < items.count, Self.precedes(items[right], items[smallest]) { smallest = right }
                if smallest == parent { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return first
    }

    private static func precedes(_ a: (priority: Double, node: Int), _ b: (priority: Double, node: Int)) -> Bool {
        a.priority < b.priority || (a.priority == b.priority && a.node < b.node)
    }
}
