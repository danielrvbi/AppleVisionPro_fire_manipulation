// Compiles the bundled Metal kernel sources exactly as the app does at runtime
// (concatenated, via MTLDevice.makeLibrary(source:)) using the Mac's GPU.
// Usage: swiftc Tools/check_metal.swift -o build/check_metal && build/check_metal FireOpus/VFX/*.metal
import Foundation
import Metal

var source = ""
for (i, path) in CommandLine.arguments.dropFirst().enumerated() {
    var text = try String(contentsOfFile: path, encoding: .utf8)
    if i > 0 {
        text = text.replacingOccurrences(of: "#include <metal_stdlib>", with: "")
            .replacingOccurrences(of: "using namespace metal;", with: "")
    }
    source += text + "\n"
}
let device = MTLCreateSystemDefaultDevice()!
do {
    let library = try device.makeLibrary(source: source, options: nil)
    print("OK:", library.functionNames.sorted())
} catch {
    print("Metal compile error:\n\(error)")
    exit(1)
}
