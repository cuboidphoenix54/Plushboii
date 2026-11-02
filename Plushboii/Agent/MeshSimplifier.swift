import Foundation

/// Quadric-error edge-collapse decimation (Garland–Heckbert) that keeps open boundaries intact and
/// refuses collapses that would flip a face or make the surface non-manifold.
enum MeshSimplifier {
    struct Result: Sendable {
        let positions: [Vec3]
        let triangles: [Int32]
        let collapses: Int
    }

    /// Symmetric 4x4 quadric stored as its 10 unique coefficients.
    private struct Quadric {
        var a = [Double](repeating: 0, count: 10)

        mutating func add(plane p: SIMD4<Double>, weight w: Double) {
            let q = [p.x * p.x, p.x * p.y, p.x * p.z, p.x * p.w, p.y * p.y, p.y * p.z, p.y * p.w, p.z * p.z, p.z * p.w, p.w * p.w]
            for i in 0..<10 { a[i] += w * q[i] }
        }

        static func + (l: Quadric, r: Quadric) -> Quadric {
            var out = l
            for i in 0..<10 { out.a[i] += r.a[i] }
            return out
        }

        func error(_ v: Vec3) -> Double {
            let x = v.x, y = v.y, z = v.z
            return a[0] * x * x + 2 * a[1] * x * y + 2 * a[2] * x * z + 2 * a[3] * x
                + a[4] * y * y + 2 * a[5] * y * z + 2 * a[6] * y
                + a[7] * z * z + 2 * a[8] * z + a[9]
        }
    }

    private struct Entry {
        let cost: Double
        let v1: Int32
        let v2: Int32
        let stamp1: Int
        let stamp2: Int
        let target: Vec3
    }

    private struct MinHeap {
        var items: [Entry] = []

        mutating func push(_ e: Entry) {
            items.append(e)
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                guard items[i].cost < items[p].cost else { break }
                items.swapAt(i, p)
                i = p
            }
        }

        mutating func pop() -> Entry? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count, items[l].cost < items[m].cost { m = l }
                    if r < items.count, items[r].cost < items[m].cost { m = r }
                    if m == i { break }
                    items.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
    }

    private static func key(_ a: Int32, _ b: Int32) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }

    static func simplify(positions inputPositions: [Vec3], triangles inputTriangles: [Int32], targetFaces: Int) -> Result {
        var positions = inputPositions
        let faceCount = inputTriangles.count / 3
        guard targetFaces >= 4, faceCount > targetFaces else {
            return Result(positions: positions, triangles: inputTriangles, collapses: 0)
        }
        var faces: [[Int32]] = (0..<faceCount).map { [inputTriangles[3 * $0], inputTriangles[3 * $0 + 1], inputTriangles[3 * $0 + 2]] }
        var alive = [Bool](repeating: true, count: faceCount)
        var liveFaces = faceCount
        var vertexFaces = [Set<Int>](repeating: [], count: positions.count)
        for (f, face) in faces.enumerated() { for v in face { vertexFaces[Int(v)].insert(f) } }

        var edgeCount: [UInt64: Int] = [:]
        for face in faces { for k in 0..<3 { edgeCount[key(face[k], face[(k + 1) % 3]), default: 0] += 1 } }
        var boundaryVertex = [Bool](repeating: false, count: positions.count)
        var quadrics = [Quadric](repeating: Quadric(), count: positions.count)

        for face in faces {
            let a = positions[Int(face[0])], b = positions[Int(face[1])], c = positions[Int(face[2])]
            let n = vcross(b - a, c - a)
            let len = vlength(n)
            guard len > 0 else { continue }
            let unit = n / len
            let plane = SIMD4<Double>(unit.x, unit.y, unit.z, -vdot(unit, a))
            for v in face { quadrics[Int(v)].add(plane: plane, weight: len / 2) }
            for k in 0..<3 where edgeCount[key(face[k], face[(k + 1) % 3])] == 1 {
                let p = positions[Int(face[k])], q = positions[Int(face[(k + 1) % 3])]
                let edge = q - p
                let side = vcross(edge, unit)
                let sl = vlength(side)
                guard sl > 0 else { continue }
                let su = side / sl
                let bp = SIMD4<Double>(su.x, su.y, su.z, -vdot(su, p))
                let weight = vlength(edge) * vlength(edge) * 10
                quadrics[Int(face[k])].add(plane: bp, weight: weight)
                quadrics[Int(face[(k + 1) % 3])].add(plane: bp, weight: weight)
                boundaryVertex[Int(face[k])] = true
                boundaryVertex[Int(face[(k + 1) % 3])] = true
            }
        }

        var stamp = [Int](repeating: 0, count: positions.count)
        var removedVertex = [Bool](repeating: false, count: positions.count)
        var heap = MinHeap()

        func neighbors(_ v: Int) -> Set<Int32> {
            var out = Set<Int32>()
            for f in vertexFaces[v] { for w in faces[f] where Int(w) != v { out.insert(w) } }
            return out
        }

        func makeEntry(_ a: Int32, _ b: Int32) -> Entry? {
            let ia = Int(a), ib = Int(b)
            let boundaryEdge = edgeCount[key(a, b)] == 1
            if boundaryVertex[ia] && boundaryVertex[ib] && !boundaryEdge { return nil }
            let candidates: [Vec3]
            if boundaryVertex[ia] && !boundaryVertex[ib] { candidates = [positions[ia]] }
            else if boundaryVertex[ib] && !boundaryVertex[ia] { candidates = [positions[ib]] }
            else if boundaryEdge { candidates = [positions[ia], positions[ib]] }
            else { candidates = [positions[ia], positions[ib], (positions[ia] + positions[ib]) / 2] }
            let q = quadrics[ia] + quadrics[ib]
            guard let best = candidates.min(by: { q.error($0) < q.error($1) }) else { return nil }
            return Entry(cost: max(0, q.error(best)), v1: a, v2: b, stamp1: stamp[ia], stamp2: stamp[ib], target: best)
        }

        for edge in edgeCount.keys {
            if let e = makeEntry(Int32(edge >> 32), Int32(edge & 0xFFFF_FFFF)) { heap.push(e) }
        }

        func collapseIsSafe(_ e: Entry) -> Bool {
            let v1 = Int(e.v1), v2 = Int(e.v2)
            let shared = vertexFaces[v1].intersection(vertexFaces[v2])
            guard !shared.isEmpty, shared.count <= 2 else { return false }
            guard neighbors(v1).intersection(neighbors(v2)).count == shared.count else { return false }
            for v in [v1, v2] {
                for f in vertexFaces[v] where !shared.contains(f) {
                    let face = faces[f]
                    let before = (0..<3).map { positions[Int(face[$0])] }
                    let after = (0..<3).map { Int(face[$0]) == v1 || Int(face[$0]) == v2 ? e.target : positions[Int(face[$0])] }
                    let nb = vcross(before[1] - before[0], before[2] - before[0])
                    let na = vcross(after[1] - after[0], after[2] - after[0])
                    let lb = vlength(nb), la = vlength(na)
                    guard lb > 0, la > 1e-12 * lb else { return false }
                    if vdot(nb, na) / (lb * la) < 0.2 { return false }
                }
            }
            return true
        }

        func removeEdges(of f: Int) {
            for k in 0..<3 {
                let ek = key(faces[f][k], faces[f][(k + 1) % 3])
                if let n = edgeCount[ek] { edgeCount[ek] = n <= 1 ? nil : n - 1 }
            }
        }

        var collapses = 0
        while liveFaces > targetFaces, let e = heap.pop() {
            let v1 = Int(e.v1), v2 = Int(e.v2)
            guard !removedVertex[v1], !removedVertex[v2], stamp[v1] == e.stamp1, stamp[v2] == e.stamp2,
                  edgeCount[key(e.v1, e.v2)] != nil, collapseIsSafe(e) else { continue }

            let shared = vertexFaces[v1].intersection(vertexFaces[v2])
            for f in shared {
                alive[f] = false
                liveFaces -= 1
                removeEdges(of: f)
                for w in faces[f] { vertexFaces[Int(w)].remove(f) }
            }
            for f in vertexFaces[v2] {
                removeEdges(of: f)
                for k in 0..<3 where faces[f][k] == e.v2 { faces[f][k] = e.v1 }
                for k in 0..<3 { edgeCount[key(faces[f][k], faces[f][(k + 1) % 3]), default: 0] += 1 }
                vertexFaces[v1].insert(f)
            }
            vertexFaces[v2] = []
            removedVertex[v2] = true
            positions[v1] = e.target
            quadrics[v1] = quadrics[v1] + quadrics[v2]
            boundaryVertex[v1] = boundaryVertex[v1] || boundaryVertex[v2]
            stamp[v1] += 1
            collapses += 1
            for n in neighbors(v1) {
                if let entry = makeEntry(e.v1, n) { heap.push(entry) }
            }
        }

        var remap = [Int32](repeating: -1, count: positions.count)
        var outPositions: [Vec3] = []
        var outTriangles: [Int32] = []
        for (f, face) in faces.enumerated() where alive[f] {
            for v in face {
                if remap[Int(v)] < 0 {
                    remap[Int(v)] = Int32(outPositions.count)
                    outPositions.append(positions[Int(v)])
                }
                outTriangles.append(remap[Int(v)])
            }
        }
        return Result(positions: outPositions, triangles: outTriangles, collapses: collapses)
    }
}
