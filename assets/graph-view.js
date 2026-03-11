/**
 * initObsidianGraph(dataUrl, selector)
 *
 * Renders an interactive D3.js v7 force-directed graph of Obsidian notes.
 * Nodes represent published notes; edges represent [[wiki-link]] connections.
 *
 * @param {string} dataUrl  - URL of graph_data.json (e.g. '/assets/graph_data.json')
 * @param {string} selector - CSS selector for the container element
 */
async function initObsidianGraph(dataUrl, selector) {
  const container = document.querySelector(selector);
  if (!container) return;

  let data;
  try {
    const resp = await fetch(dataUrl);
    data = await resp.json();
  } catch (e) {
    container.innerHTML = '<p style="padding:1rem;color:#888;">Graph data unavailable.</p>';
    return;
  }

  if (!data.nodes || data.nodes.length === 0) {
    container.innerHTML = '<p style="padding:1rem;color:#888;">No published notes yet.</p>';
    return;
  }

  const width  = container.clientWidth  || 800;
  const height = container.clientHeight || 600;

  // Count backlinks for node sizing
  const backlinks = {};
  data.nodes.forEach(n => { backlinks[n.id] = 0; });
  (data.links || []).forEach(l => {
    const tgt = typeof l.target === 'object' ? l.target.id : l.target;
    if (backlinks[tgt] !== undefined) backlinks[tgt]++;
  });

  // Assign colors by first tag
  const allTags = [...new Set(data.nodes.flatMap(n => n.tags || []))];
  const colorScale = d3.scaleOrdinal(d3.schemeTableau10).domain(allTags);
  const nodeColor = n =>
    (n.tags && n.tags.length > 0) ? colorScale(n.tags[0]) : '#69b3a2';

  const svg = d3.select(selector)
    .append('svg')
    .attr('width', '100%')
    .attr('height', height)
    .attr('viewBox', `0 0 ${width} ${height}`)
    .style('background', '#fafafa');

  // Zoom / pan
  const zoomGroup = svg.append('g');
  svg.call(d3.zoom()
    .scaleExtent([0.3, 4])
    .on('zoom', e => zoomGroup.attr('transform', e.transform))
  );

  const simulation = d3.forceSimulation(data.nodes)
    .force('link',      d3.forceLink(data.links || []).id(d => d.id).distance(90))
    .force('charge',    d3.forceManyBody().strength(-220))
    .force('center',    d3.forceCenter(width / 2, height / 2))
    .force('collision', d3.forceCollide(d => nodeRadius(d) + 4));

  function nodeRadius(d) {
    return 5 + Math.sqrt(backlinks[d.id] || 0) * 3;
  }

  // Links
  const link = zoomGroup.append('g')
    .attr('class', 'links')
    .selectAll('line')
    .data(data.links || [])
    .join('line')
    .attr('stroke', '#cccccc')
    .attr('stroke-width', 1.2);

  // Nodes
  const nodeGroup = zoomGroup.append('g')
    .attr('class', 'nodes')
    .selectAll('g')
    .data(data.nodes)
    .join('g')
    .style('cursor', 'pointer')
    .on('click', (_, d) => { window.location.href = d.url; })
    .call(d3.drag()
      .on('start', (event, d) => {
        if (!event.active) simulation.alphaTarget(0.3).restart();
        d.fx = d.x; d.fy = d.y;
      })
      .on('drag',  (event, d) => { d.fx = event.x; d.fy = event.y; })
      .on('end',   (event, d) => {
        if (!event.active) simulation.alphaTarget(0);
        d.fx = null; d.fy = null;
      })
    );

  nodeGroup.append('circle')
    .attr('r',            d => nodeRadius(d))
    .attr('fill',         d => nodeColor(d))
    .attr('stroke',       '#ffffff')
    .attr('stroke-width', 1.5);

  // Tooltip on hover
  nodeGroup.append('title').text(d => d.title);

  // Labels (only shown when zoom level is adequate; always shown for now)
  nodeGroup.append('text')
    .text(d => d.title)
    .attr('x', d => nodeRadius(d) + 3)
    .attr('y', 4)
    .attr('font-size', '10px')
    .attr('fill', '#444444')
    .style('pointer-events', 'none')
    .style('user-select', 'none');

  simulation.on('tick', () => {
    link
      .attr('x1', d => d.source.x)
      .attr('y1', d => d.source.y)
      .attr('x2', d => d.target.x)
      .attr('y2', d => d.target.y);
    nodeGroup.attr('transform', d => `translate(${d.x},${d.y})`);
  });

  // Legend
  if (allTags.length > 0) {
    const legend = svg.append('g')
      .attr('transform', 'translate(12, 12)');
    allTags.slice(0, 10).forEach((tag, i) => {
      const row = legend.append('g').attr('transform', `translate(0, ${i * 18})`);
      row.append('circle').attr('r', 5).attr('cx', 5).attr('cy', 0)
        .attr('fill', colorScale(tag));
      row.append('text').text(tag)
        .attr('x', 14).attr('y', 4)
        .attr('font-size', '11px').attr('fill', '#555555');
    });
  }
}
