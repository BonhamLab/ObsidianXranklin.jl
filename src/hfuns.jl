"""
    hfun_obsidian_graph()

Xranklin template function. Renders an interactive D3.js force-directed graph
of published vault notes and their wiki-link connections.

Usage in a Xranklin page:
    {{obsidian_graph}}

Requires `sync_vault` to have been run first (writes `/assets/graph_data.json`).
"""
function hfun_obsidian_graph()
    return """
<div id="obsidian-graph-container" style="width:100%;height:600px;border:1px solid #e0e0e0;border-radius:6px;overflow:hidden;">
  <div id="obsidian-graph" style="width:100%;height:100%;"></div>
</div>
<script src="https://d3js.org/d3.v7.min.js"></script>
<script src="/assets/graph-view.js"></script>
<script>
  document.addEventListener('DOMContentLoaded', function() {
    initObsidianGraph('/assets/graph_data.json', '#obsidian-graph');
  });
</script>
"""
end
