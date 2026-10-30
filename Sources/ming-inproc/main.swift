import Foundation
import MLXMingImage
import MLXServeCore
import MLXToolKit
import MingPlugin

// The in-process reference for the plugin: one Ming-Image lane loaded by MLXServeEngine in this process, with the lane
// configuration the worker uses (MingPlugin) and the request it would build. A cold run then a warm one; the first
// image is written to --out, and one JSON line of timings is printed. Not part of the plugin bundle.
//
//   ming-inproc [--lane int8 | bf16 | int4] [--prompt <text>] [--width 1024] [--height 1024] [--steps 12]
//               [--guidance 1] [--seed 42] [--background opaque | transparent] [--models-root <dir>] [--out <png>]
//               [--once]
//
// The width and height are the request's; the package draws its bucket's size, as through the worker. --once runs
// one job, for measuring (and the first run of a lane downloads its tier into the models root). "transparent" in the
// JSON line says whether the first image has native alpha, by the test the worker applies.
//
//   ming-inproc --decompose <png> [--lane int8 | bf16 | int4] [--plan <text>] [--layers N] [--resolution 512 | 1024]
//               [--steps 12] [--guidance 2] [--seed 42] [--models-root <dir>] [--out-dir <dir>] [--once]
//
// Design-Layer (image.decompose) instead: the layers are written to --out-dir as layers-<i>.png (0 front-most) and the
// composite as composite-0.png, the names the worker gives them.

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let started = ContinuousClock.now
let decomposePath = option("--decompose")
let quant = Quant(rawValue: option("--lane") ?? "int8") ?? .int8
let prompt = option("--prompt") ?? "a minimalist poster for a jazz festival, the words \"BLUE NOTE NIGHTS\" in bold type"
let width = Int(option("--width") ?? "") ?? 1024
let height = Int(option("--height") ?? "") ?? 1024
let steps = Int(option("--steps") ?? "") ?? defaultSteps
let guidance = Double(option("--guidance") ?? "") ?? defaultGuidance
let seed = UInt64(option("--seed") ?? "") ?? 42
let background: T2IBackground? = option("--background") == "transparent" ? .transparent : nil
let once = args.contains("--once")
let outPath = option("--out")
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)

// The budget Gaea sends a worker on a large Mac (wiresWeights off, the automatic pool cap).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))

func finish(_ result: inout [String: Any]) throws {
    if let run2 = result["run2_s"] as? Double { result["cold_s"] = seconds(since: started) - run2 }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

if let decomposePath {
    let plan = option("--plan")
    let layers = Int(option("--layers") ?? "")
    let resolution = Int(option("--resolution") ?? "") ?? 1024
    let layerSteps = Int(option("--layer-steps") ?? "") ?? defaultLayerSteps
    let layerGuidance = Double(option("--layer-guidance") ?? "") ?? defaultLayerGuidance
    let outDir = option("--out-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
    var result: [String: Any] = ["model": layerModelID, "lane": quant.rawValue, "resolution": resolution,
                                 "steps": layerSteps, "guidance": layerGuidance, "seed": seed]
    let id = PackageID(layerModelID)
    _ = try await engine.register(MingImageLayerPackage.registration, configuration: layerConfiguration(quant: quant), id: id)
    var clock = ContinuousClock.now
    _ = try await engine.prepare(.layerDecompose, package: id)
    result["prepare_s"] = seconds(since: clock)
    let input = Image(format: .png, data: try Data(contentsOf: URL(fileURLWithPath: decomposePath)))
    let request = LayerDecomposeRequest(image: input, spec: plan, layerCount: layers, resolution: resolution,
                                        steps: layerSteps, guidanceScale: layerGuidance, seed: seed)
    for run in once ? ["run1"] : ["run1", "run2"] {
        clock = ContinuousClock.now
        let response = try await engine.run(request, package: id)
        result["\(run)_s"] = seconds(since: clock)
        if run == "run1", let stack = response as? LayerDecomposeResponse {
            result["layer_count"] = stack.layers.count
            result["out_width"] = stack.layers.first?.width
            result["out_height"] = stack.layers.first?.height
            if let outDir {
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                for (i, layer) in stack.layers.enumerated() {
                    try layer.data.write(to: outDir.appending(path: "layers-\(i).png"))
                }
                try stack.composite?.data.write(to: outDir.appending(path: "composite-0.png"))
            }
        }
    }
    try finish(&result)
    exit(0)
}

let size = try drawnSize((width, height))
var result: [String: Any] = ["model": modelID, "lane": quant.rawValue, "width": width, "height": height, "steps": steps,
                             "guidance": guidance, "seed": seed, "background": background == .transparent ? "transparent" : "opaque"]

let id = PackageID(modelID)
_ = try await engine.register(MingImageT2IPackage.registration, configuration: configuration(quant: quant), id: id)

var clock = ContinuousClock.now
_ = try await engine.prepare(.textToImage, package: id)
result["prepare_s"] = seconds(since: clock)

let request = T2IRequest(prompt: prompt, width: size.request.width, height: size.request.height, steps: steps,
                         guidanceScale: guidance, seed: seed, background: background)
for run in once ? ["run1"] : ["run1", "run2"] {
    clock = ContinuousClock.now
    let response = try await engine.run(request, package: id)
    result["\(run)_s"] = seconds(since: clock)
    if run == "run1", let image = (response as? T2IResponse)?.image {
        result["out_width"] = image.width
        result["out_height"] = image.height
        result["transparent"] = hasNativeAlpha(png: image.data)
        if let outPath { try image.data.write(to: URL(fileURLWithPath: outPath)) }
    }
}
try finish(&result)
