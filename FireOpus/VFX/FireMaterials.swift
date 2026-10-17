import Foundation
import RealityKit

/// Programmatically built ShaderGraph materials for the fire layers.
///
/// Every layer shares the same vertex stage (geometry modifier): the compute kernel writes all four
/// corners of a quad at the particle centre, and the vertex stage pushes them out toward the camera
/// of the eye being rendered, stretched along the particle's motion axis. That keeps the fire
/// stereoscopically correct and needs no head-pose plumbing.
enum FireMaterials {
    enum Kind {
        case flame   // additive, noise-eroded tongue with inner filaments
        case spark   // additive, soft disc (embers, sparks, glow)
        case smoke   // alpha-blended, noise-eroded wisp
        case shade   // alpha-blended soft dark haze behind the flame (contrast on bright passthrough)
    }

    @MainActor
    static func make(_ kind: Kind, noise: TextureResource, gain: Float, falloff: Float = 2.0) async throws -> ShaderGraphMaterial {
        let descriptor = try makeDescriptor(kind, noise: noise, gain: gain, falloff: falloff)
        let program = try await ShaderGraphMaterial.Program(descriptor: descriptor)
        var material = ShaderGraphMaterial(program: program)
        material.faceCulling = .none
        material.writesDepth = false
        material.readsDepth = true
        return material
    }

    /// Builds the node graph and returns a fresh (disconnected) program descriptor.
    private static func makeDescriptor(_ kind: Kind, noise: TextureResource, gain: Float, falloff: Float) throws -> ShaderGraphMaterial.Program.Descriptor {
        let b = try GraphBuilder(
            name: "fire_\(kind)",
            inputs: [
                .init(name: "noiseTex", type: .texture),
                .init(name: "gain", type: .float, defaultValue: .float(gain)),
                .init(name: "falloff", type: .float, defaultValue: .float(falloff)),
            ],
            outputs: [
                .init(name: "surface", type: .surfaceShader),
                .init(name: "geometryModifier", type: .geometryModifier),
            ])

        try buildBillboard(b)
        switch kind {
        case .flame: try buildFlameSurface(b)
        case .spark: try buildSparkSurface(b)
        case .smoke: try buildSmokeSurface(b)
        case .shade: try buildShadeSurface(b)
        }

        var descriptor = try ShaderGraphMaterial.Program.Descriptor(
            inferredFrom: b.graph,
            inputValues: [
                "noiseTex": .textureResource(noise),
                "gain": .float(gain),
                "falloff": .float(falloff),
            ])
        descriptor.blendMode = (kind == .smoke || kind == .shade) ? .alpha : .add
        return descriptor
    }

    // MARK: - Vertex stage

    private static func buildBillboard(_ b: GraphBuilder) throws {
        let pos = try b.node("ND_realitykit_geometry_modifier_position", port: "position")
        let cam = try b.node("ND_realitykit_cameraposition_vector3", ["space": b.str("model")])
        let axis = try b.node("ND_realitykit_geometry_modifier_normal", port: "normal")
        let uv0 = try b.node("ND_realitykit_geometry_modifier_uv0", port: "uv0")
        let uv1 = try b.node("ND_realitykit_geometry_modifier_uv1", port: "uv1")
        let col = try b.node("ND_realitykit_geometry_modifier_color", port: "color")

        let view = try b.normalize3(b.sub3(cam, pos))
        let jitter = try b.constant(.float3([1e-5, 2e-5, 0]))
        let right = try b.normalize3(b.add3(b.cross3(axis, view), jitter))
        let along = try b.cross3(view, right) // axis projected onto the view plane

        let cx = try b.add(b.mul(b.x(uv0), 2), -1)
        let cy = try b.add(b.mul(b.y(uv0), 2), -1)
        let offset = try b.add3(b.scale3(right, b.mul(cx, b.x(uv1))),
                                b.scale3(along, b.mul(cy, b.y(uv1))))

        let gm = try b.node("ND_realitykit_geometrymodifier_vertexshader",
                            ["modelPositionOffset": offset, "uv0": uv0, "uv1": uv1, "color": col])
        try b.output("geometryModifier", gm)
    }

    // MARK: - Shared fragment pieces

    private struct Varyings {
        let uv: GraphBuilder.Ref
        let size: GraphBuilder.Ref
        let temperature: GraphBuilder.Ref
        let alpha: GraphBuilder.Ref
        let age: GraphBuilder.Ref
        let seed: GraphBuilder.Ref
    }

    private static func varyings(_ b: GraphBuilder) throws -> Varyings {
        let uv = try b.node("ND_realitykit_surface_uv0", port: "uv0")
        let size = try b.node("ND_realitykit_surface_uv1", port: "uv1")
        let c = try b.node("ND_realitykit_surface_color", port: "color")
        return Varyings(uv: uv, size: size,
                        temperature: try b.channel(ofColor4: c, "r"),
                        alpha: try b.channel(ofColor4: c, "g"),
                        age: try b.channel(ofColor4: c, "b"),
                        seed: try b.channel(ofColor4: c, "a"))
    }

    private static func sampleNoise(_ b: GraphBuilder, _ uv: GraphBuilder.Ref) throws -> GraphBuilder.Ref {
        try b.node("ND_image_color3", [
            "file": b.argument("noiseTex"),
            "texcoord": uv,
            "uaddressmode": b.str("periodic"),
            "vaddressmode": b.str("periodic"),
            "filtertype": b.str("linear"),
        ])
    }

    /// Black-body-ish ramp: black -> deep red -> orange -> amber -> yellow -> white.
    private static func fireRamp(_ b: GraphBuilder, _ t: GraphBuilder.Ref) throws -> GraphBuilder.Ref {
        var c = try b.lerpColor(b.color(0, 0, 0), b.color(0.40, 0.035, 0.004), b.smoothstep(t, 0.0, 0.18))
        c = try b.lerpColor(c, b.color(1.0, 0.20, 0.018), b.smoothstep(t, 0.14, 0.42))
        c = try b.lerpColor(c, b.color(1.0, 0.48, 0.09), b.smoothstep(t, 0.38, 0.66))
        c = try b.lerpColor(c, b.color(1.0, 0.78, 0.36), b.smoothstep(t, 0.62, 0.88))
        c = try b.lerpColor(c, b.color(1.0, 0.96, 0.86), b.smoothstep(t, 0.84, 1.12))
        return c
    }

    private static func unlit(_ b: GraphBuilder, color: GraphBuilder.Ref, opacity: GraphBuilder.Ref, premultiplied: Bool) throws {
        let surface = try b.node("ND_realitykit_unlit_surfaceshader", [
            "color": color,
            "opacity": opacity,
            "hasPremultipliedAlpha": b.constant(.bool(premultiplied)),
            "applyPostProcessToneMap": b.constant(.bool(false)),
        ])
        try b.output("surface", surface)
    }

    // MARK: - Flame

    private static func buildFlameSurface(_ b: GraphBuilder) throws {
        let v = try varyings(b)
        let u = try b.x(v.uv), w = try b.y(v.uv)  // w = 1 at the leading (upper) end
        let qx = try b.add(b.mul(u, 2), -1)
        let qy = try b.add(b.mul(w, 2), -1)

        // Teardrop: wide at the root, tapering toward the tip.
        let taper = try b.sub(b.f(1), b.mul(w, 0.55))
        let wx = try b.div(qx, taper)
        let r = try b.length2(b.vec2(wx, qy))
        let mask = try b.saturate(b.oneMinus(r))

        // Noise coordinates: aspect-corrected, scrolling with particle age (flow inside the tongue).
        let aspect = try b.div(b.y(v.size), b.max(b.x(v.size), 1e-4))
        let nu = try b.add(b.mul(u, 0.55), b.mul(v.seed, 7.31))
        let nv = try b.add(b.sub(b.mul(b.mul(w, aspect), 0.32), b.mul(v.age, 0.9)), b.mul(v.seed, 3.17))
        let n = try sampleNoise(b, b.vec2(nu, nv))
        let nr = try b.channel(ofColor3: n, "r")
        let ng = try b.channel(ofColor3: n, "g")

        // Erode the soft mask with noise -> ragged, licking edges.
        let density = try b.saturate(b.mul(b.sub(mask, b.mul(b.oneMinus(nr), 0.78)), 3.2))
        // Ridged filaments only inside the body.
        let filaments = try b.mul(b.pow(ng, 3.0), b.smoothstep(mask, 0.05, 0.5))

        let heat = try b.add(b.mul(v.temperature, b.add(b.mul(density, 0.5), 0.5)),
                             b.mul(b.mul(filaments, v.temperature), 0.35))
        let col = try fireRamp(b, heat)
        let energy = try b.mul(b.mul(b.add(density, b.mul(filaments, 0.55)), v.alpha), b.argument("gain"))
        try unlit(b, color: b.scaleColor(col, energy), opacity: b.f(0), premultiplied: true)
    }

    // MARK: - Sparks / embers / glow

    private static func buildSparkSurface(_ b: GraphBuilder) throws {
        let v = try varyings(b)
        let qx = try b.add(b.mul(b.x(v.uv), 2), -1)
        let qy = try b.add(b.mul(b.y(v.uv), 2), -1)
        let r = try b.length2(b.vec2(qx, qy))
        let d = try b.pow(b.saturate(b.oneMinus(r)), b.argument("falloff"))
        let col = try fireRamp(b, v.temperature)
        let energy = try b.mul(b.mul(d, v.alpha), b.argument("gain"))
        try unlit(b, color: b.scaleColor(col, energy), opacity: b.f(0), premultiplied: true)
    }

    // MARK: - Smoke

    private static func buildSmokeSurface(_ b: GraphBuilder) throws {
        let v = try varyings(b)
        let u = try b.x(v.uv), w = try b.y(v.uv)
        let qx = try b.add(b.mul(u, 2), -1)
        let qy = try b.add(b.mul(w, 2), -1)
        let mask = try b.saturate(b.oneMinus(b.length2(b.vec2(qx, qy))))

        let nu = try b.add(b.mul(u, 0.45), b.mul(v.seed, 5.13))
        let nv = try b.add(b.sub(b.mul(w, 0.45), b.mul(v.age, 0.35)), b.mul(v.seed, 2.29))
        let n = try sampleNoise(b, b.vec2(nu, nv))
        let nb = try b.channel(ofColor3: n, "b")

        let density = try b.mul(b.saturate(b.mul(b.sub(mask, b.mul(b.oneMinus(nb), 0.72)), 2.0)),
                                b.smoothstep(mask, 0.0, 0.6))
        let col = try b.lerpColor(b.color(0.075, 0.07, 0.068), b.color(0.42, 0.15, 0.04), b.saturate(v.temperature))
        let opacity = try b.mul(b.mul(density, v.alpha), b.argument("gain"))
        try unlit(b, color: col, opacity: opacity, premultiplied: false)
    }

    // MARK: - Heat shade

    private static func buildShadeSurface(_ b: GraphBuilder) throws {
        let v = try varyings(b)
        let qx = try b.add(b.mul(b.x(v.uv), 2), -1)
        let qy = try b.add(b.mul(b.y(v.uv), 2), -1)
        let d = try b.pow(b.saturate(b.oneMinus(b.length2(b.vec2(qx, qy)))), b.argument("falloff"))
        let col = try b.color(0.035, 0.012, 0.004)
        try unlit(b, color: col, opacity: b.mul(b.mul(d, v.alpha), b.argument("gain")), premultiplied: false)
    }
}
