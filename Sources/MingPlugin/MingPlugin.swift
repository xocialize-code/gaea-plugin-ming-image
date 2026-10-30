import CoreGraphics
import Foundation
import ImageIO
import GaeaPluginKit
import GaeaProtocol
import MLXMingImage
import MLXToolKit
import MingImage

// gaea-plugin-ming-image: inclusionAI's Ming-Image 0.1 Design (MIT) as a Gaea plugin, on ming-image-swift through
// MLXServeEngine (Gaea AB-T-0388). A Ling-mini MoE MLLM conditions a Z-Image-shaped DiT; the VAE decodes RGBA.
// It is a design model: posters, signage, layouts and text on a page, from natural language or a JSON layer schema.
//
// One model, `ming-image`, on image.generate, with the package's quants as lanes: int8 (the default, as in
// mlx-image-runtime's catalog), bf16 and int4, with the package's measured footprints. Every lane peaks while the MLLM
// conditions the prompt; the conditioner loads for each job and is freed before the denoise. Weights come from the
// models root Gaea sends in configure (MLXEngine's store by default); the engine materializes a missing tier.
//
// Sizes follow the reference's buckets: a request is drawn in the 1024² bucket, or the 2048² one when its area needs
// it, at the bucket's nearest aspect, then resized to cover the requested aspect. So the size drawn is the bucket's,
// not the one asked; it is reported in `effective`, with `size_snapped` when it differs. Up to 2048² in area.
//
// `x-ming.background: transparent` asks for native alpha (the package's `background: .transparent`): the measured
// phrase, a retry at the same seed when the first comes back opaque, and an alpha floor. The output is a straight-alpha
// PNG. Glass and other transparent subjects can still come back opaque, so every image is checked, and one without alpha
// carries the warning `background_opaque` (Base §10.1 lets an engine use a code no registry defines).
//
// Not offered yet: the Design-Layer checkpoint's layer decomposition, which no MES operation describes (AB-T-0388).

public let modelID = "ming-image"
public let maxPixels = 2048 * 2048
public let defaultSteps = 12, defaultGuidance = 1.0

/// The package configuration for one lane; ming-inproc builds the same one.
public func configuration(quant: Quant) -> MingImageConfiguration { MingImageConfiguration(quant: quant) }

/// The MES size a job asks for (`size`, or `aspect` with `megapixels`, Image profile §2), else nil.
func requestedSize(_ job: Job) throws -> (Int, Int)? {
    if let size = job.param("size") {
        guard let w = size["width"]?.intValue, let h = size["height"]?.intValue, w > 0, h > 0 else {
            throw GPPError(.invalidRequest, "size is {width, height} in pixels.")
        }
        return (w, h)
    }
    if let aspect = job.param("aspect")?.stringValue {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw GPPError(.invalidRequest, "aspect is W:H, e.g. 16:9.") }
        let pixels = (job.param("megapixels")?.doubleValue ?? 1.0) * 1_000_000
        let height = (pixels * parts[1] / parts[0]).squareRoot()
        return (Int(height * parts[0] / parts[1]), Int(height))
    }
    return nil
}

/// The size the package draws for a request: within the 2048² area cap, the smallest bucket covering the area, its
/// nearest aspect, resized to cover the requested aspect (MingImageT2IPackage.run, the reference's process_ratio).
public func drawnSize(_ size: (Int, Int)) throws -> (request: (width: Int, height: Int), drawn: (width: Int, height: Int)) {
    var (w, h) = (Double(size.0), Double(size.1))
    if w * h > Double(maxPixels) {
        let scale = (Double(maxPixels) / (w * h)).squareRoot()
        w *= scale
        h *= scale
    }
    let request = (width: Int(w), height: Int(h))
    guard request.width >= 64, request.height >= 64,
          Double(max(request.width, request.height)) / Double(min(request.width, request.height)) <= 8 else {
        throw GPPError(.invalidRequest, "Ming-Image draws up to 2048² in area, at most 8:1; \(size.0)×\(size.1) doesn't fit.",
                       detail: ["param": "size"])
    }
    let buckets = MingTask.textToImage.resolutionBuckets
    let bucket = MingTask.textToImage.resolve(
        buckets.first { $0 * $0 >= request.width * request.height } ?? buckets.last!)
    let resized = MingSizes.processRatio(oriH: request.height, oriW: request.width, highres: bucket).resize
    return (request, (resized.width, resized.height))
}

/// Whether a PNG has native alpha by the package's gate metric (`MingNativeAlpha.isTransparent`). The image is drawn the
/// way ForgeCore's EngineImageCoding draws one, into premultiplied sRGB RGBA8, which leaves alpha exact.
public func hasNativeAlpha(png: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
    let (w, h) = (image.width, image.height)
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
        guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return drawn && MingNativeAlpha.isTransparent(rgba: rgba)
}

/// MES image.generate: one engine call per image, each with seed + i. The operation runs its calls itself, so it can
/// look at each image a transparent request returns.
let generate = EngineOperation("image.generate") { job, session in
    let calls = try generateCalls(job)
    let transparent = job.param("x-ming.background")?.stringValue == "transparent"
    var outputs: [Output] = []
    var opaque: [Int] = []
    for (i, call) in calls.enumerated() {
        try Task.checkCancellation()
        guard let image = (try await session.run(call.request) as? T2IResponse)?.image, image.format == .png else {
            throw GPPError(.modelError, "Ming-Image returned no PNG.")
        }
        let url = session.outputDir.appending(path: "image-\(i).png")
        try image.data.write(to: url)
        outputs.append(.file("images", url, mediaType: "image/png"))
        if transparent, !hasNativeAlpha(png: image.data) { opaque.append(i) }
    }
    var warnings = calls.first?.warnings ?? []
    if !opaque.isEmpty {
        let which = calls.count == 1 ? "The image" : "Image \(opaque.map { String($0 + 1) }.joined(separator: ", ")) of \(calls.count)"
        warnings.append(Warning(code: "background_opaque",
                                message: "\(which) came back without a transparent background, after the retry. Scenes that "
                                    + "fill the frame, and glass, often do; image.matte can cut a subject out.",
                                param: "x-ming.background"))
    }
    return RunResult(outputs: outputs, effective: calls.first?.effective ?? [:], warnings: warnings)
}

/// The engine calls for an image.generate job, validated: one per image.
public func generateCalls(_ job: Job) throws -> [EngineCall] {
    guard let prompt = try job.text("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GPPError(.invalidRequest, "image.generate needs a prompt.")
    }
    let asked = try requestedSize(job) ?? (1024, 1024)
    let size = try drawnSize(asked)
    let steps = job.param("x-ming.steps")?.intValue ?? defaultSteps
    guard (1...50).contains(steps) else { throw GPPError(.invalidRequest, "x-ming.steps is 1–50.") }
    let guidance = job.param("x-ming.guidance")?.doubleValue ?? defaultGuidance
    guard (1...10).contains(guidance) else { throw GPPError(.invalidRequest, "x-ming.guidance is 1–10.") }
    let count = job.param("count")?.intValue ?? 1
    guard (1...8).contains(count) else { throw GPPError(.invalidRequest, "count is 1–8.") }
    let background = job.param("x-ming.background")?.stringValue ?? "opaque"
    guard ["opaque", "transparent"].contains(background) else {
        throw GPPError(.invalidRequest, "x-ming.background is opaque or transparent.")
    }
    var warnings: [Warning] = []
    if size.drawn != (asked.0, asked.1) {
        warnings.append(Warning(code: "size_snapped",
                                message: "Drew \(size.drawn.width)×\(size.drawn.height) for \(asked.0)×\(asked.1): Ming-Image draws "
                                    + "in its 1024² and 2048² buckets, covering the requested aspect.",
                                param: "size"))
    }
    if let negative = job.param("negative_prompt")?.stringValue, !negative.isEmpty {
        warnings.append(Warning(code: "negative_prompt_ignored",
                                message: "Ming-Image conditions on the prompt alone, so a negative prompt does nothing.",
                                param: "negative_prompt"))
    }
    if job.param("prompt_enhance")?.stringValue == "on" {
        warnings.append(Warning(code: "prompt_enhance_ignored", message: "This plugin doesn't rewrite prompts; Gaea's enhancer does.",
                                param: "prompt_enhance"))
    }
    // Image profile §2: a request without a seed still gets one, reported in effective.
    let seed = job.seed ?? UInt64.random(in: 0..<(1 << 31))
    var effective: [String: JSONValue] = [
        "size": ["width": .int(Int64(size.drawn.width)), "height": .int(Int64(size.drawn.height))],
        "seed": .int(Int64(seed)), "count": .int(Int64(count)), "x-ming.steps": .int(Int64(steps)),
    ]
    if guidance > 1 { effective["x-ming.guidance"] = .double(guidance) }
    if background == "transparent" { effective["x-ming.background"] = "transparent" }
    return (0..<count).map { i in
        EngineCall(T2IRequest(prompt: prompt, width: size.request.width, height: size.request.height, steps: steps,
                              guidanceScale: guidance, seed: seed + UInt64(i),
                              background: background == "transparent" ? .transparent : nil),
                   effective: effective, warnings: warnings)
    }
}

public let lanes: [LaneDefinition] = [Quant.int8, .bf16, .int4].map { quant in
    LaneDefinition(id: quant.rawValue, default: quant == .int8, configuration: configuration(quant: quant))
}

let params: JSONValue = [
    "type": "object",
    "properties": [
        "x-ming.steps": [
            "type": "integer", "minimum": 1, "maximum": 50, "default": .int(Int64(defaultSteps)),
            "description": "Denoising steps. The Design profile uses 12.",
            "x-mes-ui": ["widget": "slider", "label": "Steps", "advanced": true],
        ],
        "x-ming.guidance": [
            "type": "number", "minimum": 1, "maximum": 10, "default": .double(defaultGuidance),
            "description": "Classifier-free guidance. The Design profile runs without it (1).",
            "x-mes-ui": ["widget": "slider", "label": "Guidance", "advanced": true],
        ],
        "x-ming.background": [
            "type": "string", "enum": ["opaque", "transparent"], "default": "opaque",
            "description": .string("transparent draws the design on native alpha: a straight-alpha PNG, for stickers, "
                + "logos and overlays. An image that still comes back opaque carries the warning background_opaque."),
            "x-mes-ui": ["widget": "picker", "label": "Background"],
        ],
    ],
    "additionalProperties": false,
]

let offerModel: JSONValue = [
    "id": .string(modelID), "title": "Ming-Image Design",
    "license": ["spdx": "MIT", "commercial_use": true, "terms_url": "https://huggingface.co/inclusionAI/Ming-Image-0.1-Design"],
    "memory_class": "large", "speed_class": "standard", "quality_tiers": ["standard", "best"],
    "notes": .string("A design model: posters, signage, layouts and legible text, from natural language or a JSON layer schema. "
        + "Drawn in its 1024² or 2048² bucket at the requested aspect (the size drawn is reported). "
        + "x-ming.background: transparent gives native alpha; glass and see-through subjects may still come back opaque. "
        + "Not for exact operational text; negative prompts do nothing."),
]

public let mingPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.ming-image",
    version: "0.3.0",
    minGaea: "0.7.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-ming-image",
    title: "Ming-Image",
    summary: "inclusionAI Ming-Image 0.1 Design and Design-Layer (MIT): a Ling-mini MoE MLLM conditioning a Z-Image-shaped "
        + "DiT, for design work (posters, signage, layouts and text, in 1024² and 2048² buckets) and for splitting a flat "
        + "design into editable layers.",
    license: "Apache-2.0",
    executable: "gaea-ming-image-worker",
    models: [
        .engine(MingImageT2IPackage.self, id: modelID, title: "Ming-Image Design", lanes: lanes, operations: [generate]),
        layerModel,
    ],
    offers: [
        PluginManifest.Offer(operation: "image.generate", profile: "image", model: offerModel, params: params,
                             defaults: ["count": 1],
                             limits: PluginManifest.Limits(maxPixels: maxPixels, minSide: 64, maxSide: 4096, sizeMultiple: 1)),
        layerOffer,
    ])
