# gaea-plugin-ming-image

inclusionAI's **Ming-Image 0.1 Design** (MIT) as a [Gaea](https://github.com/xocialize-code/gaea) plugin: a Ling-mini
MoE MLLM conditioning a Z-Image-shaped DiT, with an RGBA VAE. It is a design model, for posters, signage, layouts and
text on the page, from natural language or a JSON layer schema. It is built on
[GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[ming-image-swift](https://github.com/xocialize/ming-image-swift), runs in its own process, and speaks the Gaea Plugin
Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-ming-image
```

## What it offers

| Model | MES operation | Quality tiers | Notes |
|---|---|---|---|
| `ming-image` | `image.generate` | standard, best | 12 steps without CFG (the reference's Design profile). Not a default: Gaea's routes don't change, so a request reaches it by naming it. |

- **Sizes.** Ming-Image draws in two buckets, 1024² and 2048²: a request takes the smallest bucket that covers its
  area, at that bucket's nearest aspect, resized to cover the requested aspect: a 768×512 request is drawn at
  1248×832. The worker reports the size drawn in `effective`, with `size_snapped`; Gaea then returns the size the
  request asked for. Up to 2048² in area, at most 8:1.
- **`count`**: 1–8 images, each with `seed + i`. A request without a seed gets one, reported in `effective`.
- **Options**, as MES extensions: `x-ming.steps` (1–50), `x-ming.guidance` (1–10, 1 turns CFG off) and
  `x-ming.background` (below).
- **Transparent backgrounds** (0.2.0): `x-ming.background: "transparent"` draws the design on native alpha and returns a
  straight-alpha PNG, for stickers, logos and overlays. The package prepends its measured phrase, retries once at the same
  seed with a second phrase when the first image comes back opaque (about twice the time), and floors α below 0.1 to 0.
  The worker checks every image by the package's gate metric (more than 10% of pixels with α ≤ 12), and one that is still
  opaque carries the warning `background_opaque`. Scenes that fill the frame do; so, sometimes, does glass. `image.matte`
  can cut a subject out of such an image.
- **Negative prompts** do nothing (`negative_prompt_ignored`): the model conditions on the prompt alone.
- **Not offered yet:** the Design-Layer checkpoint's layer decomposition. No MES operation returns an image's layers yet.

## Lanes and memory

| Lane | Resident | Peak while running | Gaea schedules |
|---|---|---|---|
| `int8` (default) | 7.9 GB | 24.4 GB | 32.3 GB |
| `bf16` | 13.5 GB | 44.1 GB | 57.6 GB |
| `int4` | 7.9 GB | 14.6 GB | 22.5 GB |

Every lane peaks while the MLLM conditions the prompt: it loads for each job, conditions, and is freed before the
denoise. int8 is the default, as in mlx-image-runtime's catalog; speed is within about 10% across lanes (the DiT is
compute-bound, and 8-bit in every tier), so the lanes trade memory and fidelity. When int8 doesn't fit, Gaea loads a
smaller lane and warns (`lane_fallback`, G-23); `gaea models lane ming-image int4` makes another lane the default.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default). Each lane reads its published tier,
`mlx-community/Ming-Image-0.1-Design-{8bit,bf16,4bit}`, there and downloads it on `prepare` or `materialize` when it's
missing. The package refuses a snapshot whose quantization isn't the lane's, or the Design-Layer checkpoint.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`build-plugin.sh` copies every SwiftPM resource bundle into the plugin, not only MLX's metallib: Ming-Image's
tokenizer config names no tokenizer class, so swift-transformers reads its bundled fallback configs through
`Bundle.module`, and without the bundle the worker traps. `check-plugin.sh` generates one 1024² image at int8 in 6
steps against the weights in MLXEngine's store, with every `.build` folder hidden, then shows that the bare worker
outside the bundle finds no metallib. `scripts/release.sh` builds, checks, notarizes with the fleet's `mlx-notary`
profile, and publishes the GitHub release.

`ming-inproc` (its header lists the options) is not part of the plugin: it runs the same lane in-process through
MLXServeEngine, the reference Gaea's runs are compared against.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` runs three seeded jobs over GPP on the signed bundle and through `ming-inproc` and needs each pair the
same: int8 at 1024², int8 at 1280×720, int8 at 768×512 (drawn at 1248×832), and int4 at 1024².

## Licence

The plugin is Apache-2.0 (Gaea G-21). Ming-Image 0.1 Design's weights are MIT (inclusionAI), and ming-image-swift is MIT.
