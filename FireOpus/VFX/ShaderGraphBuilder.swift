import CoreGraphics
import Foundation
import RealityKit

/// A tiny DSL over the visionOS 27 programmatic `ShaderGraph` API (MaterialX node library).
/// Lets the fire materials be written as readable expressions instead of Reality Composer Pro graphs.
final class GraphBuilder {
    struct Ref {
        let node: String
        let port: String?
    }

    enum BuildError: Error, CustomStringConvertible {
        case missingDefinition(String)
        var description: String {
            switch self {
            case .missingDefinition(let name): "ShaderGraph node definition not found: \(name)"
            }
        }
    }

    let library = ShaderGraph.NodeLibrary(version: .default)
    let graph: ShaderGraph
    private var counter = 0

    init(name: String, inputs: [ShaderGraph.NodeDefinition.Input], outputs: [ShaderGraph.NodeDefinition.Output]) throws {
        graph = try ShaderGraph(named: name, inputs: inputs, outputs: outputs, nodeLibrary: library)
    }

    // MARK: Core

    func node(_ definition: String, _ inputs: [String: Ref] = [:], port: String? = nil) throws -> Ref {
        guard let def = library.definition(named: definition) else { throw BuildError.missingDefinition(definition) }
        var made = try library.makeNode(from: def)
        counter += 1
        made.name = "n\(counter)_\(def.functionalName)"
        let key = try graph.addNode(made)
        for (inputPort, ref) in inputs {
            try graph.connect(ref.node, outputPort: ref.port, to: key, inputPort: inputPort)
        }
        return Ref(node: key, port: port)
    }

    func constant(_ value: ShaderGraph.Value) throws -> Ref {
        Ref(node: try graph.addConstant(value), port: nil)
    }

    func f(_ v: Float) throws -> Ref { try constant(.float(v)) }
    func str(_ s: String) throws -> Ref { try constant(.string(s)) }
    func color(_ r: Float, _ g: Float, _ b: Float) throws -> Ref {
        try constant(.cgColor3(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                                       components: [CGFloat(r), CGFloat(g), CGFloat(b), 1])!))
    }

    func argument(_ name: String) -> Ref { Ref(node: graph.arguments.name, port: name) }

    func output(_ name: String, _ ref: Ref) throws {
        try graph.connect(ref.node, outputPort: ref.port, to: graph.results.name, inputPort: name)
    }

    // MARK: Float math

    func add(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_add_float", ["in1": a, "in2": b]) }
    func sub(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_subtract_float", ["in1": a, "in2": b]) }
    func mul(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_multiply_float", ["in1": a, "in2": b]) }
    func div(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_divide_float", ["in1": a, "in2": b]) }
    func mul(_ a: Ref, _ k: Float) throws -> Ref { try mul(a, f(k)) }
    func add(_ a: Ref, _ k: Float) throws -> Ref { try add(a, f(k)) }
    func pow(_ a: Ref, _ e: Ref) throws -> Ref { try node("ND_power_float", ["in1": a, "in2": e]) }
    func pow(_ a: Ref, _ e: Float) throws -> Ref { try pow(a, f(e)) }
    func max(_ a: Ref, _ k: Float) throws -> Ref { try node("ND_max_float", ["in1": a, "in2": f(k)]) }
    func saturate(_ a: Ref) throws -> Ref { try node("ND_clamp_float", ["in": a, "low": f(0), "high": f(1)]) }
    func smoothstep(_ a: Ref, _ lo: Float, _ hi: Float) throws -> Ref {
        try node("ND_smoothstep_float", ["in": a, "low": f(lo), "high": f(hi)])
    }
    /// 1 - x
    func oneMinus(_ a: Ref) throws -> Ref { try sub(f(1), a) }

    // MARK: Vector helpers

    func x(_ v2: Ref) throws -> Ref { try node("ND_swizzle_vector2_float", ["in": v2, "channels": str("x")]) }
    func y(_ v2: Ref) throws -> Ref { try node("ND_swizzle_vector2_float", ["in": v2, "channels": str("y")]) }
    func channel(ofColor4 c: Ref, _ ch: String) throws -> Ref {
        try node("ND_swizzle_color4_float", ["in": c, "channels": str(ch)])
    }
    func channel(ofColor3 c: Ref, _ ch: String) throws -> Ref {
        try node("ND_swizzle_color3_float", ["in": c, "channels": str(ch)])
    }
    func vec2(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_combine2_vector2", ["in1": a, "in2": b]) }
    func length2(_ v: Ref) throws -> Ref { try node("ND_magnitude_vector2", ["in": v]) }

    func sub3(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_subtract_vector3", ["in1": a, "in2": b]) }
    func add3(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_add_vector3", ["in1": a, "in2": b]) }
    func scale3(_ a: Ref, _ s: Ref) throws -> Ref { try node("ND_multiply_vector3FA", ["in1": a, "in2": s]) }
    func normalize3(_ a: Ref) throws -> Ref { try node("ND_normalize_vector3", ["in": a]) }
    func cross3(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_crossproduct_vector3", ["in1": a, "in2": b]) }

    // MARK: Colour helpers

    /// lerp(a, b, t) — note MaterialX `mix(fg, bg, m)` = bg * (1 - m) + fg * m.
    func lerpColor(_ a: Ref, _ b: Ref, _ t: Ref) throws -> Ref { try node("ND_mix_color3", ["fg": b, "bg": a, "mix": t]) }
    func scaleColor(_ c: Ref, _ s: Ref) throws -> Ref { try node("ND_multiply_color3FA", ["in1": c, "in2": s]) }
    func addColor(_ a: Ref, _ b: Ref) throws -> Ref { try node("ND_add_color3", ["in1": a, "in2": b]) }
}
