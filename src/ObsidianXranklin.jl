"""
ObsidianXranklin — Obsidian vault publishing plugin for Xranklin.jl

## Quick start

```julia
using ObsidianXranklin

ObsidianXranklin.sync_vault(
    "vault/",      # path to Obsidian vault git submodule
    ".";           # Xranklin site root
    publish_folders = ["public/"],   # vault folders to auto-publish
    output_dir = "notes"             # site subdirectory for output
)
```

## What it does

- Discovers publishable notes (via `publish: true` frontmatter or `publish_folders`)
- Converts Obsidian YAML frontmatter (`---`) to Xranklin TOML (`+++`)
- Resolves `[[wiki-links]]` to standard Markdown links
- Converts `> [!NOTE]` callout blocks to HTML `<div>` elements
- Renders Obsidian Bases (`.base`) files as HTML tables
- Copies vault media assets to the site's `_assets/` directory
- Writes `_assets/graph_data.json` for the interactive note graph

## Xranklin integration

Add `using ObsidianXranklin` to your site's `utils.jl`. This makes
`hfun_obsidian_graph` available as `{{obsidian_graph}}` in any page template.
"""
module ObsidianXranklin

export sync_vault, watch_vault, NoteInfo

using YAML
using JSON3
using Dates
import Hyperscript as HS

const node = HS.m

include("types.jl")
include("frontmatter.jl")
include("callouts.jl")
include("wikilinks.jl")
include("bases.jl")
include("vault.jl")
include("hfuns.jl")

end
