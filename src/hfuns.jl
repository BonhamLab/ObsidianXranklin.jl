"""
    hfun_callout(params::Vector{String}) -> String

Xranklin template function. Opens a callout block.

Usage in a page:
    {{callout note My Title}}
    Content goes here.
    {{end_callout}}

`params[1]` is the callout type (e.g. `warning`, `note`).
Everything after is joined as the title; defaults to the display name if omitted.
"""
function hfun_callout(params::Vector{String})
    callout_type = lowercase(params[1])
    title = if length(params) > 1
        join(params[2:end], " ")
    else
        get(CALLOUT_DISPLAY_NAMES, callout_type, titlecase(callout_type))
    end
    return """<div class="callout callout-$(callout_type)">""" *
           string(node("div", class="callout-title", title)) *
           """<div class="callout-content">"""
end

"""
    hfun_end_callout() -> String

Closes a callout block opened by `{{callout ...}}`.
"""
hfun_end_callout() = "</div></div>"

"""
    hfun_obsidian_graph()

Xranklin template function. Renders an interactive D3.js force-directed graph
of published vault notes and their wiki-link connections.

Usage in a Xranklin page:
    {{obsidian_graph}}

Requires `sync_vault` to have been run first (writes `/assets/graph_data.json`).
"""
function hfun_obsidian_graph()
    container = node("div", id="obsidian-graph-container",
        style="width:100%;height:600px;border:1px solid #e0e0e0;border-radius:6px;overflow:hidden;",
        node("div", id="obsidian-graph", style="width:100%;height:100%;")
    )
    d3_script = node("script", src="https://d3js.org/d3.v7.min.js")
    gv_script  = node("script", src="/assets/graph-view.js")
    init_script = node("script",
        "\n  document.addEventListener('DOMContentLoaded', function() {\n" *
        "    initObsidianGraph('/assets/graph_data.json', '#obsidian-graph');\n" *
        "  });\n"
    )
    return string(container, "\n", d3_script, "\n", gv_script, "\n", init_script, "\n")
end
