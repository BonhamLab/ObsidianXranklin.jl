"""
    transform_wikilinks(content::String, note_index::Dict, output_dir::String)
                        -> (String, Vector{String})

Transform Obsidian wiki-links in content to standard Markdown links.
Returns (transformed_content, vector_of_linked_slugs).
"""
function transform_wikilinks(content::String, note_index::Dict, output_dir::String)
    edges = String[]

    # Image/file embeds: ![[image.ext]] → ![image](/assets/image.ext)
    # Must run before note embed pattern
    content = replace(content, r"!\[\[([^\]\|]+\.(png|jpg|jpeg|gif|svg|webp|pdf))\]\]"i =>
        function(m)
            img = match(r"!\[\[([^\]]+)\]\]", m).captures[1]
            "![$(basename(img))](/_assets/$(basename(img)))"
        end
    )

    # Note embeds: ![[note name]] → inline link (full embed requires server-side processing)
    content = replace(content, r"!\[\[([^\]]+)\]\]" =>
        function(m)
            raw = match(r"!\[\[([^\]]+)\]\]", m).captures[1]
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
                "[$alias]"
            end
        end
    )

    # Simple wiki-links: [[note name]] and [[note#section]]
    content = replace(content, r"\[\[([^\]]+)\]\]" =>
        function(m)
            raw = match(r"\[\[([^\]]+)\]\]", m).captures[1]
            # Strip section reference for URL lookup
            note_name = strip(split(raw, "#")[1])
            display_name = isempty(note_name) ? raw : note_name
            key = lowercase(note_name)
            if haskey(note_index, key)
                push!(edges, key)
                "[$display_name]($(note_index[key]))"
            else
                @warn "Unresolved wiki-link: [[$raw]]"
                "$display_name"
            end
        end
    )

    return content, unique(edges)
end
