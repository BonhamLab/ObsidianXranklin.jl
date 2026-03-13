"""
    note_slug(filepath::String) -> String

Convert a file path to a URL-friendly slug.
"""
function note_slug(filepath::String)
    stem = splitext(basename(filepath))[1]
    slug = lowercase(stem)
    slug = replace(slug, r"\s+" => "-")
    slug = replace(slug, r"[^a-z0-9-]" => "-")
    slug = replace(slug, r"-+" => "-")
    return strip(slug, '-')
end

"""
    should_publish(fm::Dict, rel_path::String, publish_folders::Vector{String}) -> Bool

Determine whether a vault note should be published.

Rules (in order):
1. `publish: false` in frontmatter → never publish
2. `publish: true` in frontmatter → always publish
3. File is inside one of `publish_folders` → publish
4. Otherwise → do not publish
"""
function should_publish(fm::Dict, rel_path::String, publish_folders::Vector{String})
    pub = get(fm, "publish", nothing)
    pub === false && return false
    pub === true  && return true
    for folder in publish_folders
        startswith(rel_path, folder) && return true
    end
    return false
end

"""
    discover_notes(vault_path, publish_folders) -> Vector{NoteInfo}

Walk the vault and return all notes that should be published.
"""
function discover_notes(vault_path::String, publish_folders::Vector{String})
    notes = NoteInfo[]

    for (root, dirs, files) in walkdir(vault_path)
        # Skip hidden directories (including .obsidian)
        filter!(d -> !startswith(d, "."), dirs)

        for file in files
            endswith(file, ".md") || continue
            abs_path = joinpath(root, file)
            rel_path = relpath(abs_path, vault_path)

            content = read(abs_path, String)
            fm, _ = parse_frontmatter(content)

            should_publish(fm, rel_path, publish_folders) || continue

            title = string(get(fm, "title", splitext(file)[1]))
            raw_tags = get(fm, "tags", String[])
            tags = raw_tags isa AbstractVector ? string.(raw_tags) : [string(raw_tags)]

            push!(notes, NoteInfo(abs_path, note_slug(file), title, tags, fm))
        end
    end

    return notes
end

"""
    build_note_index(notes, output_dir) -> Dict{String, String}

Build a lookup table mapping note names/slugs/titles to their URL paths.
"""
function build_note_index(notes, output_dir::String)
    index = Dict{String, String}()
    for note in notes
        url = "/$output_dir/$(note.slug)/"
        slug = note.slug
        index[lowercase(slug)] = url
        # Slug with hyphens replaced by spaces (handles [[note name]] → note-name)
        index[replace(lowercase(slug), "-" => " ")] = url
        # Original filename stem (may differ from slug)
        stem = lowercase(splitext(basename(note.src_path))[1])
        index[stem] = url
        index[replace(stem, "-" => " ")] = url
        index[lowercase(note.title)] = url
    end
    return index
end

"""
    build_graph_data(notes, edges) -> Dict

Build the JSON data structure consumed by the D3.js graph view.
`edges` maps source slug → vector of target slugs.
"""
function build_graph_data(notes::Vector{NoteInfo}, edges::Dict{String, Vector{String}})
    nodes = [
        Dict("id" => n.slug, "title" => n.title,
             "url" => "/notes/$(n.slug)/", "tags" => n.tags)
        for n in notes
    ]
    links = []
    for (src, targets) in edges
        for tgt in targets
            push!(links, Dict("source" => src, "target" => tgt))
        end
    end
    return Dict("nodes" => nodes, "links" => links)
end

"""
    copy_vault_assets(vault_path, assets_dir)

Copy image/media files from the vault into the site's _assets directory.
Skips files that already exist at the destination.
"""
function copy_vault_assets(vault_path::String, assets_dir::String)
    media_exts = Set([".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".pdf"])
    for (root, dirs, files) in walkdir(vault_path)
        filter!(d -> !startswith(d, "."), dirs)
        for file in files
            ext = lowercase(splitext(file)[2])
            ext in media_exts || continue
            src = joinpath(root, file)
            safe_name = replace(file, " " => "-")
            dst = joinpath(assets_dir, safe_name)
            isfile(dst) || cp(src, dst)
        end
    end
end

"""
    sync_vault(vault_path, site_path; publish_folders, output_dir, index_note)

Main entry point. Discovers publishable notes in `vault_path`, transforms them
(callouts → HTML, YAML → TOML, wiki-links → markdown), and writes them to
`<site_path>/<output_dir>/<slug>/index.md`.

Also writes `<site_path>/_assets/graph_data.json` for the interactive graph view
and copies media assets.

# Arguments
- `vault_path`: path to the Obsidian vault (e.g., `"vault/"`)
- `site_path`: root of the Xranklin site (e.g., `"."`)
- `publish_folders`: vault-relative folder prefixes whose notes are auto-published
- `output_dir`: site subdirectory for published notes (default: `"notes"`)
- `index_note`: slug of the note to use as the section homepage (`/<output_dir>/`).
  When set, that note is also written to `<output_dir>/index.md` so that the
  section root URL resolves directly to it. Corresponds to `obsidian_home` in
  the site's `config.jl`.
"""
function sync_vault(vault_path::String, site_path::String;
                    publish_folders::Vector{String}=String[],
                    output_dir::String="notes",
                    index_note::Union{String,Nothing}=nothing)
    vault_path = abspath(vault_path)
    site_path  = abspath(site_path)
    out_dir    = joinpath(site_path, output_dir)
    assets_dir = joinpath(site_path, "_assets")

    mkpath(out_dir)
    mkpath(assets_dir)

    # 1. Discover publishable notes
    notes = discover_notes(vault_path, publish_folders)
    @info "ObsidianXranklin: found $(length(notes)) publishable notes"
    isempty(notes) && return notes

    # 2. Build note index for wiki-link resolution
    note_index = build_note_index(notes, output_dir)

    # 3. Process each note
    all_edges = Dict{String, Vector{String}}()
    for note in notes
        content = read(note.src_path, String)

        # Transform callouts first (before frontmatter conversion which may reorder)
        content = transform_callouts(content)

        # Convert YAML frontmatter to TOML
        content, _ = convert_frontmatter(content)

        # Resolve wiki-links and collect graph edges
        content, edges = transform_wikilinks(content, note_index, output_dir)
        all_edges[note.slug] = edges

        # Inline any .base file embeds
        content = process_base_embeds(content, vault_path, notes, output_dir)

        # Write transformed note
        note_out = joinpath(out_dir, note.slug)
        mkpath(note_out)
        write(joinpath(note_out, "index.md"), content)
    end

    # 4. Write section index if an index_note is configured
    if index_note !== nothing
        home = findfirst(n -> n.slug == index_note, notes)
        if home !== nothing
            cp(joinpath(out_dir, index_note, "index.md"),
               joinpath(out_dir, "index.md"), force=true)
        else
            @warn "ObsidianXranklin: index_note \"$index_note\" not found among published notes"
        end
    end

    # 5. Copy vault media assets
    copy_vault_assets(vault_path, assets_dir)

    # 6. Write graph data JSON
    graph_data = build_graph_data(notes, all_edges)
    open(joinpath(assets_dir, "graph_data.json"), "w") do io
        JSON3.write(io, graph_data)
    end

    # 7. Copy graph-view.js to site assets
    js_src = joinpath(@__DIR__, "..", "assets", "graph-view.js")
    if isfile(js_src)
        cp(js_src, joinpath(assets_dir, "graph-view.js"), force=true)
    end

    @info "ObsidianXranklin: sync complete — $(length(notes)) notes published to /$output_dir/"
    return notes
end
