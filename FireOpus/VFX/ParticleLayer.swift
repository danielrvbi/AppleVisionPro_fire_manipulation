import Foundation
import Metal
import RealityKit

// Swift mirrors of the structs in FireSimulation.metal (all 16-byte vectors -> identical layout).

struct SpinePoint {
    var posRadius: SIMD4<Float>
    var velHeat: SIMD4<Float>

    init(position: SIMD3<Float>, radius: Float, velocity: SIMD3<Float> = .zero, heat: Float) {
        posRadius = SIMD4(position, radius)
        velHeat = SIMD4(velocity, heat)
    }
    var position: SIMD3<Float> { SIMD3(posRadius.x, posRadius.y, posRadius.z) }
    var radius: Float { posRadius.w }
    var velocity: SIMD3<Float> { SIMD3(velHeat.x, velHeat.y, velHeat.z) }
    var heat: Float { velHeat.w }
}

struct LayerParams {
    var time = SIMD4<Float>.zero      // time, dt, frame, intensity
    var counts = SIMD4<UInt32>.zero   // active, spine count, capacity, reset
    var life = SIMD4<Float>.zero      // min life, max life, spawn radius factor, spawn lift
    var size = SIMD4<Float>.zero      // start/peak/end half-width, velocity stretch
    var motion = SIMD4<Float>.zero    // buoyancy, drag, curl strength, curl scale
    var motion2 = SIMD4<Float>.zero   // curl speed, cohesion, inherit velocity, flow along spine
    var heat = SIMD4<Float>.zero      // temp birth, temp death, alpha scale, max stretch
    var range = SIMD4<Float>.zero     // s min, s max, axis mode, flow mode
    var extra2 = SIMD4<Float>.zero    // cohesion decay, flicker, reference radius, spread growth
    var shape = SIMD4<Float>.zero     // convergence toward the spine axis
}

/// Shared Metal objects.
@MainActor
final class FireGPU {
    static let shared: FireGPU? = FireGPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let simulatePipeline: MTLComputePipelineState
    let noisePipeline: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = Self.compileKernels(device: device),
              let sim = library.makeFunction(name: "simulateFire"),
              let noise = library.makeFunction(name: "generateFireNoise"),
              let simPSO = try? device.makeComputePipelineState(function: sim),
              let noisePSO = try? device.makeComputePipelineState(function: noise)
        else { return nil }
        self.device = device
        self.queue = queue
        self.simulatePipeline = simPSO
        self.noisePipeline = noisePSO
    }

    /// Kernels are bundled as source and compiled on device (no offline Metal Toolchain needed).
    private static func compileKernels(device: MTLDevice) -> MTLLibrary? {
        let files = ["FireSimulation", "NoiseTexture"]
        var source = ""
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "metal", subdirectory: "Shaders"),
                  var text = try? String(contentsOf: url, encoding: .utf8) else {
                NSLog("FireGPU: missing kernel source \(name).metal")
                return nil
            }
            if !source.isEmpty {
                // the second file's preamble is already present
                text = text.replacingOccurrences(of: "#include <metal_stdlib>", with: "")
                text = text.replacingOccurrences(of: "using namespace metal;", with: "")
            }
            source += text + "\n"
        }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        do {
            return try device.makeLibrary(source: source, options: options)
        } catch {
            NSLog("FireGPU: kernel compile failed: \(error)")
            return nil
        }
    }

    /// Generates the tileable flame-detail noise texture on the GPU.
    func makeNoiseTexture(size: Int = 256) throws -> TextureResource {
        let desc = LowLevelTexture.Descriptor(textureType: .type2D, pixelFormat: .rgba8Unorm,
                                              width: size, height: size, depth: 1, mipmapLevelCount: 1,
                                              textureUsage: [.shaderRead, .shaderWrite])
        let llt = try LowLevelTexture(descriptor: desc)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "FireGPU", code: 1)
        }
        let tex = llt.replace(using: cb)
        enc.setComputePipelineState(noisePipeline)
        enc.setTexture(tex, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (size + 15) / 16, height: (size + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        return try TextureResource(from: llt)
    }
}

/// One GPU particle population rendered as one LowLevelMesh with one material.
@MainActor
final class ParticleLayer {
    let name: String
    let capacity: Int
    let mesh: LowLevelMesh
    let entity: ModelEntity
    var params = LayerParams()

    private let particles: MTLBuffer
    private var needsReset = true

    static let vertexStride = 64

    init(name: String, capacity: Int, material: some Material, sortOrder: Int32, sortGroup: ModelSortGroup, gpu: FireGPU) throws {
        self.name = name
        self.capacity = capacity

        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = capacity * 4
        desc.indexCapacity = capacity * 6
        desc.indexType = .uint32
        desc.vertexAttributes = [
            .init(semantic: .color, format: .float4, layoutIndex: 0, offset: 0),
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 16),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 28),
            .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 40),
            .init(semantic: .uv1, format: .float2, layoutIndex: 0, offset: 48),
        ]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: Self.vertexStride)]
        mesh = try LowLevelMesh(descriptor: desc)

        mesh.withUnsafeMutableIndices { raw in
            let idx = raw.bindMemory(to: UInt32.self)
            for q in 0..<capacity {
                let v = UInt32(q * 4), i = q * 6
                idx[i + 0] = v; idx[i + 1] = v + 1; idx[i + 2] = v + 2
                idx[i + 3] = v + 2; idx[i + 4] = v + 1; idx[i + 5] = v + 3
            }
        }
        // Zero the vertices so nothing renders before the first simulation step.
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
        }
        let bounds = BoundingBox(min: [-4, -4, -4], max: [4, 4, 4])
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: capacity * 6, topology: .triangle, bounds: bounds)])

        guard let buf = gpu.device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * 4 * capacity,
                                              options: .storageModePrivate) else {
            throw NSError(domain: "ParticleLayer", code: 1)
        }
        particles = buf

        let resource = try MeshResource(from: mesh)
        entity = ModelEntity(mesh: resource, materials: [material])
        entity.name = name
        entity.components.set(ModelSortGroupComponent(group: sortGroup, order: sortOrder))
    }

    func reset() { needsReset = true }

    func encode(into cb: MTLCommandBuffer, gpu: FireGPU, spine: [SpinePoint]) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        var p = params
        p.counts.z = UInt32(capacity)
        p.counts.y = UInt32(spine.count)
        p.counts.w = needsReset ? 1 : 0
        needsReset = false

        let vertexBuffer = mesh.replace(bufferIndex: 0, using: cb)
        enc.setComputePipelineState(gpu.simulatePipeline)
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBytes(&p, length: MemoryLayout<LayerParams>.stride, index: 1)
        spine.withUnsafeBytes { raw in
            enc.setBytes(raw.baseAddress!, length: raw.count, index: 2)
        }
        enc.setBuffer(vertexBuffer, offset: 0, index: 3)
        let w = gpu.simulatePipeline.threadExecutionWidth
        enc.dispatchThreadgroups(MTLSize(width: (capacity + w - 1) / w, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
    }
}
