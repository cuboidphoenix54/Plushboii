import Foundation

/// Exact pattern-drafting calculators that the persona assistants call instead of doing arithmetic in the language model.
/// Formulas follow the "Plush Pattern Drafting Masterclass" guide. Lengths are unit-agnostic: results come back in
/// whatever unit the inputs used.
public enum PatternGeometryTool: String, CaseIterable, Sendable {
    case sphereGores, cylinder, frustum, dart, headGusset, chibiHead

    public struct Result: Sendable, Equatable {
        public let title: String
        public let lines: [String]
        public var text: String { ([title] + lines.map { "• " + $0 }).joined(separator: "\n") }
    }

    public enum ToolError: LocalizedError, Equatable {
        case missing(String)
        case outOfRange(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let name): "Missing argument: \(name)"
            case .outOfRange(let message): message
            }
        }
    }

    /// Argument names and meaning, used to brief the model that picks the tool.
    public var signature: String {
        switch self {
        case .sphereGores:
            "sphereGores(radius, gores, latitudeDegrees optional, default 0 = equator): gore width and length for a sphere"
        case .cylinder:
            "cylinder(diameter, height, seamAllowance optional, default 0): flat piece for a cylinder body"
        case .frustum:
            "frustum(bigRadius, smallRadius, height): cone-segment slant, volume and flat sector pattern"
        case .dart:
            "dart(largeCircumference, smallCircumference, frontShare optional, default 0.75): dart intake split"
        case .headGusset:
            "headGusset(sidePerimeter, sideHeight): three-piece head gusset size, perimeter is nose apex to neck joint"
        case .chibiHead:
            "chibiHead(totalHeight, headFraction optional, default 0.4, headWidth optional): chibi head and body sizing"
        }
    }

    public func run(_ args: [String: Double]) throws -> Result {
        func value(_ name: String, in range: ClosedRange<Double> = 0.0001...100_000) throws -> Double {
            guard let number = args[name] else { throw ToolError.missing(name) }
            guard number.isFinite, range.contains(number) else {
                throw ToolError.outOfRange("\(name) = \(number) is outside \(range.lowerBound)...\(range.upperBound)")
            }
            return number
        }
        func optional(_ name: String, default fallback: Double, in range: ClosedRange<Double>) throws -> Double {
            guard args[name] != nil else { return fallback }
            return try value(name, in: range)
        }

        switch self {
        case .sphereGores:
            let radius = try value("radius")
            let gores = try value("gores", in: 3...64)
            guard gores == gores.rounded() else { throw ToolError.outOfRange("gores must be a whole number") }
            let latitude = try optional("latitudeDegrees", default: 0, in: -89...89)
            let width = 2 * .pi * radius * cos(latitude * .pi / 180) / gores
            let length = .pi * radius
            let theta = (90 - latitude) * .pi / 180
            let tangentWidth = 2 * radius * tan(.pi / gores) * sin(theta)
            return Result(title: "Sphere gores (r = \(f(radius)), \(Int(gores)) gores)", lines: [
                "Gore width at latitude \(f(latitude))°: \(f(width)) (circumference arc ÷ gores)",
                "Gore length pole to pole: \(f(length))",
                "Guide's tangent-form width 2r·tan(π/n)·sin θ: \(f(tangentWidth)) (straight-edge variant; the arc width is the seam length to sew)",
            ])

        case .cylinder:
            let diameter = try value("diameter")
            let height = try value("height")
            let allowance = try optional("seamAllowance", default: 0, in: 0...1000)
            let circumference = .pi * diameter
            return Result(title: "Cylinder (d = \(f(diameter)), h = \(f(height)))", lines: [
                "Circumference (flat width before allowance): \(f(circumference))",
                "Cut piece with seam allowance on every edge: \(f(circumference + 2 * allowance)) × \(f(height + 2 * allowance))",
                "Allowance added after the geometry, not to the diameter",
            ])

        case .frustum:
            let big = try value("bigRadius")
            let small = try value("smallRadius")
            let height = try value("height")
            guard big > small else { throw ToolError.outOfRange("bigRadius must exceed smallRadius; use cylinder for equal radii") }
            let slant = (pow(big - small, 2) + height * height).squareRoot()
            let outerSlant = slant * big / (big - small)
            let innerSlant = slant * small / (big - small)
            let angle = 360 * big / outerSlant
            let volume = .pi * height * (small * small + small * big + big * big) / 3
            return Result(title: "Frustum (R = \(f(big)), r = \(f(small)), h = \(f(height)))", lines: [
                "Slant height: \(f(slant))",
                "Volume: \(f(volume)) (cubed units)",
                "Flat pattern: annular sector, outer radius \(f(outerSlant)), inner radius \(f(innerSlant)), sweep \(f(angle))°",
                "Arc lengths: outer \(f(2 * .pi * big)) × (\(f(angle))/360), full circles are 2πR = \(f(2 * .pi * big)) and 2πr = \(f(2 * .pi * small))",
            ])

        case .dart:
            let large = try value("largeCircumference")
            let small = try value("smallCircumference")
            guard large > small else { throw ToolError.outOfRange("largeCircumference must exceed smallCircumference") }
            let share = try optional("frontShare", default: 0.75, in: 0...1)
            let intake = large - small
            return Result(title: "Dart intake", lines: [
                "Total intake: \(f(intake))",
                "Front: \(f(intake * share)), back: \(f(intake * (1 - share))) (front share \(f(share * 100))%)",
                "Darts shorten the adjoining panel perimeters by this amount",
            ])

        case .headGusset:
            let perimeter = try value("sidePerimeter")
            let height = try value("sideHeight")
            let width = height * 2 / 3
            return Result(title: "Head gusset (side perimeter \(f(perimeter)), side height \(f(height)))", lines: [
                "Gusset length: \(f(perimeter))",
                "Gusset width: \(f(width)) (two-thirds of side height); half-on-fold width: \(f(width / 2))",
                "Wider reads baby-like, narrower reads adult or sleek",
            ])

        case .chibiHead:
            let total = try value("totalHeight")
            let fraction = try optional("headFraction", default: 0.4, in: 0.1...0.7)
            let headHeight = total * fraction
            var lines = [
                "Head height: \(f(headHeight)) (\(f(fraction * 100))% of total)",
                "Head circumference estimate: \(f(.pi * headHeight)) (guide formula (total ÷ head ratio) × π)",
            ]
            if args["headWidth"] != nil {
                let width = try value("headWidth")
                lines.append("Body width 60-70% of head width: \(f(width * 0.6)) to \(f(width * 0.7))")
            }
            return Result(title: "Chibi proportions (total height \(f(total)))", lines: lines)
        }
    }

    private func f(_ number: Double) -> String {
        String(format: "%.2f", number)
    }
}
