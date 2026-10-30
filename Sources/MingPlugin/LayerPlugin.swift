import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXMingImage
import MLXToolKit
import MingImage

// ming-image-layer: inclusionAI's Ming-Image 0.1 Design-Layer (MIT) on MES image.decompose (Image §3.2, RFC 0004), over
// ming-image-swift's MingImageLayerPackage (MLXEngine `layerDecompose`, Gaea AB-T-0390). A flat design in, its layers
// out: straight-alpha RGBA, front-most first, the background last, plus the model's own composite when asked.
//
// The package works at its 1024 bucket (512 for `quality: draft`) at the input's aspect, and the worker returns that
// size, reported in `effective.size`; Gaea's normalizer brings the layers to the input's size. The layer plan is the
// prompt, front-most first. The package reads a count stated in it ("Decompose this image into 4 layers …"); the
// worker refuses one that contradicts `layer_count` or is above 12, the package's measured envelope. With neither, the
// package draws 4 layers without a plan and 5 with one (the reference's parse default), and `effective.layer_count` says
// how many came back.

public let layerModelID = "ming-image-layer"
public let maxLayerCount = 12
public let defaultLayerSteps = 12, defaultLayerGuidance = 2.0

/// The package configuration for one lane of the layer model; ming-inproc builds the same one.
public func layerConfiguration(quant: Quant) -> MingImageLayerConfiguration { MingImageLayerConfiguration(quant: quant) }

/// What an image.decompose job asks of the package, validated, and the values it will use.
public struct DecomposePlan: Sendable {
    public var request: LayerDecomposeRequest
    /// The request's `outputs` include `composite`.
    public var composite: Bool
    public var effective: [String: JSONValue]
}

/// The engine request for an image.decompose job (Image §3.2).
public func decomposePlan(_ job: Job) throws -> DecomposePlan {
    let image = try job.image("image")
    let plan = try job.text("prompt")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let spec = plan?.isEmpty == false ? plan : nil
    let layerCount = job.param("layer_count")?.intValue
    if let layerCount, !(1...maxLayerCount).contains(layerCount) {
        throw GPPError(.invalidRequest, "layer_count is 1–\(maxLayerCount) for Ming-Image Design-Layer.",
                       detail: ["param": "layer_count"])
    }
    if let spec, let stated = MingLayerPrompt.statedNumLayers(spec) {
        guard stated <= maxLayerCount else {
            throw GPPError(.invalidRequest, "The plan asks for \(stated) layers; Ming-Image Design-Layer makes at most "
                + "\(maxLayerCount).", detail: ["param": "prompt"])
        }
        if let layerCount, layerCount != stated {
            throw GPPError(.invalidRequest, "layer_count \(layerCount) contradicts the plan, which asks for \(stated) layers.",
                           detail: ["param": "layer_count"])
        }
    }
    let outputs = job.param("outputs")?.arrayValue?.compactMap(\.stringValue) ?? ["layers"]
    guard outputs.contains("layers") else {
        throw GPPError(.invalidRequest, "outputs must include layers.", detail: ["param": "outputs"])
    }
    if let other = outputs.first(where: { !["layers", "composite"].contains($0) }) {
        throw GPPError(.invalidRequest, "image.decompose has no output \(other).", detail: ["param": "outputs"])
    }
    // The working bucket: `resolution` when the host sends one, else `quality` (draft is the reference's fast tier).
    let resolution = job.param("resolution")?.intValue ?? (job.param("quality")?.stringValue == "draft" ? 512 : 1024)
    guard [512, 1024].contains(resolution) else {
        throw GPPError(.invalidRequest, "resolution is 512 or 1024.", detail: ["param": "resolution"])
    }
    let steps = job.param("x-ming.steps")?.intValue ?? defaultLayerSteps
    guard (1...50).contains(steps) else { throw GPPError(.invalidRequest, "x-ming.steps is 1–50.") }
    let guidance = job.param("x-ming.guidance")?.doubleValue ?? defaultLayerGuidance
    guard (1...10).contains(guidance) else { throw GPPError(.invalidRequest, "x-ming.guidance is 1–10.") }
    let seed = job.seed ?? UInt64.random(in: 0..<(1 << 31))
    let effective: [String: JSONValue] = [
        "seed": .int(Int64(seed)), "resolution": .int(Int64(resolution)), "x-ming.steps": .int(Int64(steps)),
        "x-ming.guidance": .double(guidance),
    ]
    return DecomposePlan(
        request: LayerDecomposeRequest(image: image, spec: spec, layerCount: layerCount, resolution: resolution,
                                       steps: steps, guidanceScale: guidance, seed: seed),
        composite: outputs.contains("composite"), effective: effective)
}

/// MES image.decompose: one engine call, whose layers become `layers` (layers-0 front-most) and, when asked, whose
/// composite becomes `composite`.
let decompose = EngineOperation("image.decompose") { job, session in
    let plan = try decomposePlan(job)
    guard let response = try await session.run(plan.request) as? LayerDecomposeResponse, let first = response.layers.first
    else {
        throw GPPError(.modelError, "Ming-Image Design-Layer returned no layers.")
    }
    if let asked = plan.request.layerCount, response.layers.count != asked {
        throw GPPError(.modelError, "Ming-Image Design-Layer returned \(response.layers.count) layers for the \(asked) asked.")
    }
    var outputs: [Output] = []
    for (i, layer) in response.layers.enumerated() {
        let url = session.outputDir.appending(path: "layers-\(i).png")
        try layer.data.write(to: url)
        outputs.append(.file("layers", url, mediaType: "image/png"))
    }
    if plan.composite, let composite = response.composite {
        let url = session.outputDir.appending(path: "composite-0.png")
        try composite.data.write(to: url)
        outputs.append(.file("composite", url, mediaType: "image/png"))
    }
    var effective = plan.effective
    effective["layer_count"] = .int(Int64(response.layers.count))
    if let w = first.width, let h = first.height { effective["size"] = ["width": .int(Int64(w)), "height": .int(Int64(h))] }
    return RunResult(outputs: outputs, effective: effective)
}

public let layerLanes: [LaneDefinition] = [Quant.int8, .bf16, .int4].map { quant in
    LaneDefinition(id: quant.rawValue, default: quant == .int8, configuration: layerConfiguration(quant: quant))
}

let layerParams: JSONValue = [
    "type": "object",
    "properties": [
        "x-ming.steps": [
            "type": "integer", "minimum": 1, "maximum": 50, "default": .int(Int64(defaultLayerSteps)),
            "description": "Denoising steps. The Layer profile uses 12.",
            "x-mes-ui": ["widget": "slider", "label": "Steps", "advanced": true],
        ],
        "x-ming.guidance": [
            "type": "number", "minimum": 1, "maximum": 10, "default": .double(defaultLayerGuidance),
            "description": "Classifier-free guidance. The Layer profile uses 2.",
            "x-mes-ui": ["widget": "slider", "label": "Guidance", "advanced": true],
        ],
    ],
    "additionalProperties": false,
]

let layerOfferModel: JSONValue = [
    "id": .string(layerModelID), "title": "Ming-Image Design-Layer",
    "license": ["spdx": "MIT", "commercial_use": true,
                "terms_url": "https://huggingface.co/inclusionAI/Ming-Image-0.1-Design-Layer"],
    "memory_class": "large", "speed_class": "standard", "quality_tiers": ["draft", "standard", "best"],
    "notes": .string("Splits a flat design (a poster, a card, signage, a UI) into up to 12 editable RGBA layers, front-most "
        + "first. Best with a plan, front-most first: \"Layer 1: the headline text … Layer 2: the red badge …\". "
        + "draft works at 512, standard and best at 1024, at the input's aspect."),
]

/// The layer model and its offer, beside Ming-Image Design in `mingPlugin`.
let layerModel = ModelDefinition.engine(MingImageLayerPackage.self, id: layerModelID, title: "Ming-Image Design-Layer",
                                              lanes: layerLanes, operations: [decompose])

let layerOffer = PluginManifest.Offer(operation: "image.decompose", profile: "image", model: layerOfferModel,
                                      params: layerParams, limits: PluginManifest.Limits(maxLayerCount: maxLayerCount),
                                      supports: ["composite": true])
