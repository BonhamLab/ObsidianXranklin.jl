# Obsidian Bases renderer
#
# The Obsidian Bases format (2025) uses YAML with:
#   filters:
#     and:
#       - field == "value"
#       - file.tags.contains("tag")
#   views:
#     - type: table
#       name: Table
#       order:
#         - file.name      # special file.* properties
#         - file.folder
#         - tags
#         - <any frontmatter key>
#       sort:
#         - property: file.links
#           direction: ASC

"""
    render_base_file(base_path::String, notes::Vector{NoteInfo}) -> String

Parse an Obsidian Bases `.base` file and render its first table view as HTML.
"""
function render_base_file(base_path::String, notes::Vector{NoteInfo})
    content = try
        read(base_path, String)
    catch e
        @warn "Cannot read base file $base_path: $e"
        return string(node("p", node("em", "Base file unreadable: $(basename(base_path))")))
    end

    # Strip leading frontmatter from .base files (e.g. dg-publish)
    content = strip_base_frontmatter(content)

    config = try
        YAML.load(content)
    catch e
        @warn "Failed to parse .base file $base_path: $e"
        return string(node("p", node("em", "Failed to render base: $(basename(base_path))")))
    end

    (config === nothing || !(config isa Dict)) &&
        return string(node("p", node("em", "Invalid or empty base file")))

    # Apply filters
    filter_expr = get(config, "filters", nothing)
    filtered = filter_notes_for_base(notes, filter_expr)

    # Find first table view
    views = get(config, "views", Any[])
    table_view = nothing
    for v in views
        v isa Dict && get(v, "type", "") == "table" && (table_view = v; break)
    end
    table_view === nothing && (table_view = Dict())

    columns = get(table_view, "order", ["file.name"])
    sort_spec = get(table_view, "sort", nothing)

    # Sort
    if sort_spec !== nothing
        sort_spec isa AbstractVector && (sort_spec = first(sort_spec))
        if sort_spec isa Dict
            prop = get(sort_spec, "property", "file.name")
            dir  = get(sort_spec, "direction", "ASC")
            sorted = sort(filtered, by = n -> get_file_property(n, prop),
                          rev = (uppercase(string(dir)) == "DESC"))
            filtered = sorted
        end
    end

    render_base_table(filtered, columns)
end

"""Strip any leading `key: value` lines (frontmatter-style) from a .base file."""
function strip_base_frontmatter(content::String)
    # A .base file may start with bare key: value lines before the YAML mapping.
    # We detect this by checking if the first YAML.load treats them as a flat dict
    # with no `filters` or `views` keys — in that case return as-is.
    # More robustly: check for leading non-YAML-block lines.
    lines = split(content, "\n")
    i = 1
    while i <= length(lines)
        line = lines[i]
        # Stop at first line that starts a YAML block key we care about
        if startswith(strip(line), "filters:") || startswith(strip(line), "views:")
            return join(lines[i:end], "\n")
        end
        i += 1
    end
    return content
end

"""
    get_file_property(note::NoteInfo, prop::String) -> String

Retrieve a `file.*` builtin or frontmatter property from a note.
"""
function get_file_property(note::NoteInfo, prop::AbstractString)
    if prop == "file.name"
        return note.title
    elseif prop == "file.folder"
        return dirname(note.src_path)
    elseif prop == "file.mtime"
        return string(stat(note.src_path).mtime)
    elseif prop == "file.backlinks"
        return ""   # not tracked at this level
    elseif prop == "file.links" || prop == "file.outlinks"
        return ""
    elseif prop == "file.ext"
        return ".md"
    elseif prop == "file.tags"
        return join(note.tags, ", ")
    else
        return string(get(note.frontmatter, prop, ""))
    end
end

"""
    render_file_property_cell(note::NoteInfo, prop::String) -> String

Render a single table cell for `prop`, returning an HTML string.
"""
function render_file_property_cell(note::NoteInfo, prop::AbstractString)
    if prop == "file.name"
        return node("a", href="/notes/$(note.slug)/", note.title)
    elseif prop == "file.tags" || prop == "tags"
        tags = prop == "tags" ? get(note.frontmatter, "tags", note.tags) : note.tags
        tags = tags isa AbstractVector ? string.(tags) : [string(tags)]
        return join(tags, ", ")
    else
        return string(get_file_property(note, prop))
    end
end

"""Pretty-print a column header from a `file.*` property name."""
function column_header(prop::AbstractString)
    prop = replace(prop, "file." => "")
    return titlecase(replace(prop, r"[-_]" => " "))
end

"""
    render_base_table(notes, columns) -> String

Render a list of notes as an HTML `<table>` with the given column order.
"""
function render_base_table(notes::Vector{NoteInfo}, columns)
    cols = string.(columns)
    return string(
        node("table", class="obsidian-base",
            node("thead",
                node("tr", (node("th", column_header(c)) for c in cols)...)
            ),
            node("tbody",
                (node("tr",
                    (node("td", render_file_property_cell(note, c)) for c in cols)...
                ) for note in notes)...
            )
        )
    )
end

# ─── Filter expression parser ──────────────────────────────────────────────────

"""
    filter_notes_for_base(notes, filter_expr) -> Vector{NoteInfo}

Apply a Bases filter expression tree to `notes`.
Supports: `and`, `or` lists; equality `field == "value"`;
`file.tags.contains("tag")` and `file.folder.contains("path")`.
"""
function filter_notes_for_base(notes::Vector{NoteInfo}, filter_expr)
    filter_expr === nothing && return copy(notes)
    return filter(n -> eval_filter(n, filter_expr), notes)
end

function eval_filter(note::NoteInfo, expr)
    expr === nothing && return true

    if expr isa Dict
        if haskey(expr, "and")
            return all(e -> eval_filter(note, e), expr["and"])
        elseif haskey(expr, "or")
            return any(e -> eval_filter(note, e), expr["or"])
        elseif haskey(expr, "not")
            return !eval_filter(note, expr["not"])
        end
    end

    if expr isa String
        return eval_filter_string(note, expr)
    end

    if expr isa AbstractVector
        return all(e -> eval_filter(note, e), expr)
    end

    return true
end

function eval_filter_string(note::NoteInfo, expr::String)
    expr = strip(expr)

    # file.tags.contains("tag")
    m = match(r"^file\.tags\.contains\([\"'](.+?)[\"']\)$", expr)
    if m !== nothing
        tag = m.captures[1]
        return tag in note.tags
    end

    # file.folder.contains("path")
    m = match(r"^file\.folder\.contains\([\"'](.+?)[\"']\)$", expr)
    if m !== nothing
        path_frag = m.captures[1]
        return occursin(path_frag, note.src_path)
    end

    # field == "value"  or  field == value
    m = match(r"^([\w.\-]+)\s*==\s*[\"']?(.+?)[\"']?$", expr)
    if m !== nothing
        field, expected = m.captures[1], strip(m.captures[2])
        actual = string(get_file_property(note, field))
        return lowercase(actual) == lowercase(expected)
    end

    # field != "value"
    m = match(r"^([\w.\-]+)\s*!=\s*[\"']?(.+?)[\"']?$", expr)
    if m !== nothing
        field, expected = m.captures[1], strip(m.captures[2])
        actual = string(get_file_property(note, field))
        return lowercase(actual) != lowercase(expected)
    end

    @warn "Unrecognised Bases filter expression: $expr"
    return true
end

# ─── Embed handling ────────────────────────────────────────────────────────────

"""
    process_base_embeds(content, vault_path, notes, output_dir) -> String

Replace `![[name.base]]` inline embeds with rendered HTML tables.
"""
function process_base_embeds(content::String, vault_path::String,
                              notes::Vector{NoteInfo}, output_dir::String)
    replace(content, r"!\[\[([^\]]+\.base)\]\]" =>
        function(m)
            base_name = String(match(r"!\[\[([^\]]+)\]\]", m).captures[1])
            base_path = find_file_in_vault(vault_path, base_name)
            if base_path !== nothing
                "~~~\n$(render_base_file(base_path, notes))\n~~~"
            else
                @warn "Base file not found: $base_name"
                "~~~\n<p><em>Base not found: $base_name</em></p>\n~~~"
            end
        end
    )
end

function find_file_in_vault(vault_path::String, filename::String)
    for (root, dirs, files) in walkdir(vault_path)
        filter!(d -> !startswith(d, "."), dirs)
        filename in files && return joinpath(root, filename)
    end
    return nothing
end
