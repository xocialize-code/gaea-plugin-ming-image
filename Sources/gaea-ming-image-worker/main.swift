import GaeaPluginKit
import MingPlugin

// The plugin's worker: MingPlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(mingPlugin)
