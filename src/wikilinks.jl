"""
    transform_wikilinks(content::String, note_index::Dict, output_dir::String)
                        -> (String, Vector{String})

Transform Obsidian wiki-links in content to standard Markdown links.
Returns (transformed_content, vector_of_linked_slugs).
"""
function transform_wikilinks(content::String, note_index::Dict, output_dir::String)
    edges = String[]

    # ── Protect code from wikilink transformation ────────────────────────────
    # Placeholders use control characters unlikely to appear in Markdown.
    protected = Dict{String,String}()
    counter = Ref(0)
    function protect(s)
        k = "\x02P$(counter[])\x02"
        counter[] += 1
        protected[k] = s
        return k
    end

    # Fenced code blocks (``` only — ~~~ is used by Xranklin for raw HTML)
    content = replace(content, r"(?ms)^```[^\n]*\n.*?^```[ \t]*$" => protect)
    # Inline code spans (single backtick, no newlines inside)
    content = replace(content, r"`[^`\n]+`" => protect)

    # Image/file embeds: ![[image.ext]] → ![image](/assets/image.ext)
    # Must run before note embed pattern
    content = replace(content, r"!\[\[([^\]\|]+\.(png|jpg|jpeg|gif|svg|webp|pdf))\]\]"i =>
        function(m)
            img = match(r"!\[\[([^\]]+)\]\]", m).captures[1]
            name = basename(img)
            safe_name = replace(name, " " => "-")
            "![$name](/assets/vault/$safe_name)"
        end
    )

    # Note embeds: ![[note name]] → inline link (full embed requires server-side processing)
    # .base files are skipped here — handled later by process_base_embeds
    content = replace(content, r"!\[\[([^\]]+)\]\]" =>
        function(m)
            raw = match(r"!\[\[([^\]]+)\]\]", m).captures[1]
            endswith(lowercase(raw), ".base") && return m
            note_name = strip(split(raw, "#")[1])
            key = lowercase(note_name)
            if haskey(note_index, key)
                push!(edges, key)
                "> *Embedded note: [$(note_name)]($(note_index[key]))*"
            else
                "> *Embedded note: $(note_name) (not published)*"
            end
        end
    )

    # Wiki-links with alias: [[note name|alias]] and [[note#section|alias]]
    content = replace(content, r"\[\[([^\]\|#]+)(?:#[^\]\|]*)?\|([^\]]+)\]\]" =>
        function(m)
            caps = match(r"\[\[([^\]\|#]+)(?:#[^\]\|]*)?\|([^\]]+)\]\]", m).captures
            note_name = strip(caps[1])
            alias = strip(caps[2])
            key = lowercase(note_name)
            if haskey(note_index, key)
                push!(edges, key)
                "[$alias]($(note_index[key]))"
            else
                @warn "Unresolved wiki-link: [[$note_name|$alias]]"
                "[$alias](#wikilink-missing)"
            end
        end
    )

    # Simple wiki-links: [[note name]], [[note#section]], [[#anchor]]
    # Negative lookbehind avoids matching ![[...]] embeds (handled elsewhere)
    content = replace(content, r"(?<!!)\[\[([^\]]+)\]\]" =>
        function(m)
            raw = match(r"\[\[([^\]]+)\]\]", m).captures[1]
            parts = split(raw, "#", limit=2)
            note_name = strip(parts[1])
            section = length(parts) > 1 ? strip(parts[2]) : ""

            # .base files have no standalone page — render as plain name
            endswith(lowercase(note_name), ".base") && return note_name

            # Anchor-only link: [[#Section Title]] → [Section Title](#section-title)
            if isempty(note_name)
                anchor = replace(replace(lowercase(section), r"\s+" => "-"), r"[^a-z0-9-]" => "")
                return "[$section](#$anchor)"
            end

            key = lowercase(note_name)
            anchor_suffix = isempty(section) ? "" :
                "#" * replace(replace(lowercase(section), r"\s+" => "-"), r"[^a-z0-9-]" => "")
            if haskey(note_index, key)
                push!(edges, key)
                "[$note_name]($(note_index[key])$anchor_suffix)"
            else
                @warn "Unresolved wiki-link: [[$raw]]"
                "[$note_name](#wikilink-missing)"
            end
        end
    )

    # ── Restore protected code ───────────────────────────────────────────────
    for (k, v) in protected
        content = replace(content, k => v)
    end

    return content, unique(edges)
end
