import Foundation
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
// Not offered yet: native transparent backgrounds (the package's `background: transparent`) and the Design-Layer
// checkpoint's layer decomposition, which have no MES parameter or operation (AB-T-0388).

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

/// MES image.generate: one engine call per image, each with seed + i.
let generate = EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
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
    return (0..<count).map { i in
        EngineCall(T2IRequest(prompt: prompt, width: size.request.width, height: size.request.height, steps: steps,
                              guidanceScale: guidance, seed: seed + UInt64(i)),
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
    ],
    "additionalProperties": false,
]

let offerModel: JSONValue = [
    "id": .string(modelID), "title": "Ming-Image Design",
    "license": ["spdx": "MIT", "commercial_use": true, "terms_url": "https://huggingface.co/inclusionAI/Ming-Image-0.1-Design"],
    "memory_class": "large", "speed_class": "standard", "quality_tiers": ["standard", "best"],
    "notes": .string("A design model: posters, signage, layouts and legible text, from natural language or a JSON layer schema. "
        + "Drawn in its 1024² or 2048² bucket at the requested aspect (the size drawn is reported). Not for exact "
        + "operational text; negative prompts do nothing."),
]

public let mingPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.ming-image",
    version: "0.1.0",
    minGaea: "0.7.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-ming-image",
    title: "Ming-Image",
    summary: "inclusionAI Ming-Image 0.1 Design (MIT): a Ling-mini MoE MLLM conditioning a Z-Image-shaped DiT, for "
        + "design work: posters, signage, layouts and text, in 1024² and 2048² buckets.",
    license: "Apache-2.0",
    executable: "gaea-ming-image-worker",
    models: [
        .engine(MingImageT2IPackage.self, id: modelID, title: "Ming-Image Design", lanes: lanes, operations: [generate]),
    ],
    offers: [
        PluginManifest.Offer(operation: "image.generate", profile: "image", model: offerModel, params: params,
                             defaults: ["count": 1],
                             limits: PluginManifest.Limits(maxPixels: maxPixels, minSide: 64, maxSide: 4096, sizeMultiple: 1)),
    ])
