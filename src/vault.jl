"""
    read_site_config(site_path::String, varname::String, fallback)

Read a variable from the site's `config.jl` by `include`-ing it in a sandboxed
`Module`. Returns `fallback` if the file does not exist, if the variable is not
defined in it, or if the include throws an error.

This avoids polluting `Main` and prevents side effects from leaking out of the
config file evaluation context.
"""
function read_site_config(site_path::String, varname::String, fallback)
    config_path = joinpath(abspath(site_path), "config.jl")
    isfile(config_path) || return fallback
    sandbox = Module()
    try
        Base.include(sandbox, config_path)
    catch e
        @warn "ObsidianXranklin: failed to load config.jl" path=config_path exception=e
        return fallback
    end
    # Use invokelatest to bypass Julia's world-age check: bindings created by
    # Base.include run in a newer world age than the calling function.
    sym = Symbol(varname)
    Base.invokelatest(isdefined, sandbox, sym) || return fallback
    return Base.invokelatest(getfield, sandbox, sym)
end

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
    discover_notes(vault_path, publish_folders; skip_folders) -> Vector{NoteInfo}

Walk the vault and return a `NoteInfo` for every `.md` file, with `published`
set according to the publish rules. Includes unpublished notes so they can be
referenced in Bases tables.

Notes whose vault-relative path starts with any entry in `skip_folders` are
silently ignored. Hidden directories (starting with `.`) are always skipped.
The default skip list covers Obsidian-internal folders that typically contain
template syntax or private metadata rather than publishable content.
"""
function discover_notes(vault_path::String, publish_folders::Vector{String};
                        skip_folders::Vector{String}=["Templates/", "Attachments/"])
    notes = NoteInfo[]

    for (root, dirs, files) in walkdir(vault_path)
        # Skip hidden directories (including .obsidian)
        filter!(d -> !startswith(d, "."), dirs)

        for file in files
            endswith(file, ".md") || continue
            abs_path = joinpath(root, file)
            rel_path = relpath(abs_path, vault_path)
            any(startswith(rel_path, f) for f in skip_folders) && continue

            content = read(abs_path, String)
            fm, _ = parse_frontmatter(content)

            # When YAML parsing failed (empty fm) but publish: true appears in the
            # raw content, publish the note as preformatted text rather than dropping it.
            if isempty(fm) && raw_publish_flag(content)
                title = let m = match(r"(?m)^title:\s*(.+)$", content)
                    m !== nothing ? strip(m.captures[1]) : splitext(file)[1]
                end
                push!(notes, NoteInfo(
                    src_path    = abs_path,
                    slug        = note_slug(file),
                    title       = string(title),
                    tags        = String[],
                    frontmatter = Dict(),
                    published   = true,
                    raw         = true,
                ))
                continue
            end

            title = string(get(fm, "title", splitext(file)[1]))
            raw_tags = get(fm, "tags", String[])
            tags = raw_tags isa AbstractVector ? string.(raw_tags) : [string(raw_tags)]
            published = should_publish(fm, rel_path, publish_folders)

            push!(notes, NoteInfo(
                src_path    = abs_path,
                slug        = note_slug(file),
                title       = title,
                tags        = tags,
                frontmatter = fm,
                published   = published,
            ))
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
    index_vault_files(vault_path) -> Dict{String, String}

Build a filename → absolute path index for every file in the vault.
Used to resolve `![[name.base]]` embeds without repeated directory walks.
"""
function index_vault_files(vault_path::String)
    index = Dict{String, String}()
    for (root, dirs, files) in walkdir(vault_path)
        filter!(d -> !startswith(d, "."), dirs)
        for file in files
            index[file] = joinpath(root, file)
        end
    end
    return index
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
            isfile(src) || continue  # skip broken symlinks pointing outside vault
            safe_name = replace(file, " " => "-")
            dst = joinpath(assets_dir, safe_name)
            ispath(dst) || cp(src, dst)
        end
    end
end

"""
    vault_mtimes(vault_path::String; skip_folders::Vector{String}=String[]) -> Dict{String,Float64}

Return a snapshot of modification times for every `.md` file and media asset
(`.png`, `.jpg`, `.jpeg`, `.gif`, `.svg`, `.webp`, `.pdf`) inside `vault_path`.

Keys are vault-relative paths (using the OS path separator). Hidden directories
(names starting with `.`) and any directory whose relative path starts with an
entry in `skip_folders` are excluded — mirroring the filtering done by
`discover_notes`.

The returned `Dict{String,Float64}` maps `relpath => mtime` and is used by
`watch_vault` to detect changes between polling cycles.
"""
function vault_mtimes(vault_path::String;
                      skip_folders::Vector{String}=String[])
    media_exts = Set([".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".pdf"])
    mtimes = Dict{String,Float64}()
    vault_path = abspath(vault_path)

    for (root, dirs, files) in walkdir(vault_path)
        # Skip hidden directories in-place (mutating dirs affects walkdir traversal)
        filter!(d -> !startswith(d, "."), dirs)

        for file in files
            ext = lowercase(splitext(file)[2])
            (ext == ".md" || ext in media_exts) || continue

            abs_path = joinpath(root, file)
            rel_path = relpath(abs_path, vault_path)

            any(startswith(rel_path, f) for f in skip_folders) && continue

            mtimes[rel_path] = mtime(abs_path)
        end
    end

    return mtimes
end

# Module-level state for the currently active watcher.  Storing a stop flag
# (rather than throwing into the task) avoids the Julia scheduler warning that
# arises when Base.throwto is used against a task blocked inside sleep().
const _active_watcher      = Ref{Union{Task,Nothing}}(nothing)
const _active_watcher_stop = Ref{Union{Ref{Bool},Nothing}}(nothing)

"""
    stop_watcher(; timeout=1.0)

Cancel the currently running `watch_vault` background task, if any, by setting
its cooperative stop flag and waiting for it to exit.  Safe to call when no
watcher is running.
"""
function stop_watcher(; timeout::Real=1.0)
    stop_flag = _active_watcher_stop[]
    task      = _active_watcher[]
    if stop_flag !== nothing
        stop_flag[] = true
    end
    _active_watcher_stop[] = nothing
    if task !== nothing
        # The polling loop sleeps in 0.05 s ticks, so the task will see the
        # flag within one tick.  timedwait polls until done or timeout.
        timedwait(() -> istaskdone(task), timeout; pollint=0.01)
    end
    _active_watcher[] = nothing
end

"""
    watch_vault(vault_path, site_path; interval, skip_folders, publish_folders,
                output_dir, index_note) -> Task

Run an immediate `sync_vault` and then start a background polling loop that
re-runs `sync_vault` whenever any `.md` file or media asset inside `vault_path`
changes.

The watcher compares file modification times on each poll (via `vault_mtimes`)
and triggers a full re-sync when the snapshot differs from the previous one.

# Arguments
- `vault_path`: path to the Obsidian vault directory.
- `site_path`: root of the Xranklin site.
- `interval`: polling interval in seconds (default `2`). Use a smaller value
  (e.g. `0.1`) in tests to keep them fast.
- `skip_folders`: vault-relative folder prefixes to exclude from both mtime
  scanning and `sync_vault`. When `nothing` (the default), the value is read
  from the site's `config.jl` exactly as `sync_vault` does.
- `publish_folders`, `output_dir`, `index_note`: forwarded verbatim to
  `sync_vault`.

# Return value
The `Task` running the background loop. The task exits cleanly when the
module-level stop flag is set (see `stop_watcher()`), or when a second call to
`watch_vault` supersedes this one.

# Multiple-invocation safety
`watch_vault` stores the active watcher in a module-level `Ref`. If called
again while a previous watcher is running (e.g. because `utils.jl` was
re-evaluated by Xranklin's live server), the old task's stop flag is set before
the new one starts.  No `Base.throwto` is used; cancellation is cooperative via
a shared `Ref{Bool}` flag so the Julia scheduler is never disturbed.
"""
function watch_vault(vault_path::String, site_path::String;
                     interval::Real=2,
                     skip_folders::Union{Vector{String},Nothing}=nothing,
                     publish_folders::Vector{String}=String[],
                     output_dir::String="notes",
                     index_note::Union{String,Nothing}=nothing)
    vault_path = abspath(vault_path)
    site_path  = abspath(site_path)

    # Signal any previously running watcher to stop cooperatively
    stop_watcher()

    # Resolve skip_folders once (same logic as sync_vault)
    resolved_skip = if skip_folders !== nothing
        skip_folders
    else
        read_site_config(site_path, "vault_skip_folders", ["Templates/", "Attachments/"])
    end

    # Build the shared keyword arguments to forward to sync_vault on every sync
    sync_kwargs = (
        publish_folders = publish_folders,
        output_dir      = output_dir,
        index_note      = index_note,
        skip_folders    = resolved_skip,
    )

    # Initial synchronous sync before the background task starts
    sync_vault(vault_path, site_path; sync_kwargs...)

    # Snapshot mtimes after the initial sync so we don't immediately re-trigger
    last_mtimes = vault_mtimes(vault_path; skip_folders=resolved_skip)

    # Each watcher gets its own stop flag so superseded tasks exit independently
    stop = Ref{Bool}(false)
    _active_watcher_stop[] = stop

    task = @async begin
        try
            # Break the poll interval into short sub-sleeps so the stop flag is
            # checked frequently and shutdown is prompt regardless of interval size.
            tick = min(Float64(interval), 0.05)
            elapsed = 0.0
            while !stop[]
                sleep(tick)
                elapsed += tick
                stop[] && break
                if elapsed >= interval
                    elapsed = 0.0
                    current_mtimes = vault_mtimes(vault_path; skip_folders=resolved_skip)
                    if current_mtimes != last_mtimes
                        @info "ObsidianXranklin: vault change detected, re-syncing"
                        sync_vault(vault_path, site_path; sync_kwargs...)
                        last_mtimes = current_mtimes
                    end
                end
            end
        catch e
            @warn "ObsidianXranklin: watcher task exited unexpectedly" exception=e
        end
    end

    _active_watcher[] = task
    return task
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
- `skip_folders`: vault-relative folder prefixes to exclude entirely from discovery.
  When `nothing` (the default), the value is read from the `vault_skip_folders`
  variable in the site's `config.jl`. If that variable is not present, falls back
  to `["Templates/", "Attachments/"]`. Pass an explicit `Vector{String}` to
  override both sources.
"""
function sync_vault(vault_path::String, site_path::String;
                    publish_folders::Vector{String}=String[],
                    output_dir::String="notes",
                    index_note::Union{String,Nothing}=nothing,
                    skip_folders::Union{Vector{String},Nothing}=nothing)
    vault_path = abspath(vault_path)
    site_path  = abspath(site_path)

    # Resolve skip_folders: caller value > config.jl > built-in default
    resolved_skip = if skip_folders !== nothing
        skip_folders
    else
        read_site_config(site_path, "vault_skip_folders", ["Templates/", "Attachments/"])
    end

    out_dir    = joinpath(site_path, output_dir)
    assets_dir      = joinpath(site_path, "_assets")
    vault_assets_dir = joinpath(assets_dir, "vault")

    mkpath(out_dir)
    mkpath(vault_assets_dir)

    # 1. Index all vault files and notes; separate published subset for the pipeline
    vault_files = index_vault_files(vault_path)
    all_notes = discover_notes(vault_path, publish_folders; skip_folders=resolved_skip)
    notes = filter(n -> n.published, all_notes)
    @info "ObsidianXranklin: found $(length(notes)) publishable notes ($(length(all_notes)) total)"
    isempty(notes) && return notes

    # 2. Build note index for wiki-link resolution (published notes only)
    note_index = build_note_index(notes, output_dir)

    # 3. Process each note
    all_edges = Dict{String, Vector{String}}()
    for note in notes
        note_out = joinpath(out_dir, note.slug)
        mkpath(note_out)

        if note.raw
            # YAML was unparseable — publish as a preformatted plain-text page
            raw_content = read(note.src_path, String)
            # Strip the frontmatter block (--- ... ---) leaving only the body
            body = let m = match(r"^---\r?\n.*?\r?\n---\r?\n(.*)"s, raw_content)
                m !== nothing ? m.captures[1] : raw_content
            end
            escaped_title = replace(note.title, "\\" => "\\\\", "\"" => "\\\"")
            output = """
            +++
            title = "$escaped_title"
            hascode = false
            +++

            ~~~plaintext
            $body~~~
            """
            write(joinpath(note_out, "index.md"), output)
            all_edges[note.slug] = String[]
            continue
        end

        content = read(note.src_path, String)

        # Transform callouts first (before frontmatter conversion which may reorder)
        content = transform_callouts(content)

        # Convert YAML frontmatter to TOML
        content, _ = convert_frontmatter(content)

        # Resolve wiki-links and collect graph edges
        content, edges = transform_wikilinks(content, note_index, output_dir)
        all_edges[note.slug] = edges

        # Inline any .base file embeds — pass all_notes so unpublished notes appear in tables
        content = process_base_embeds(content, vault_files, all_notes, output_dir, vault_path)

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
    copy_vault_assets(vault_path, vault_assets_dir)

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
