---
name: visualize
name_zh: 可视化交互
description: Create visualizations and interactive tools directly in conversation. Proactively use to show how something works; explore 'what happens when', 'what changes', or 'help me understand'; compare or inspect; create simulations, maps, charts, graphs, and mockups.
description_zh: 直接在对话中创建可视化和交互工具，用于演示原理、探索变化、比较检查，以及制作模拟、地图、图表和原型。
---

# Visualize

Create a self-contained interactive HTML artifact and embed it directly in the conversation.

## Choose the right response

- A request for a new standalone file, website, app page, component, or other project change is not an in-conversation visualization request, even when the deliverable contains charts or interactive content.
- A request to preview, explain, or explore a proposed interface in the conversation is an in-conversation visualization request.
- Create a visual only when the user needs to see or explore it in the conversation and it materially improves the explanation. Do not create one merely because the request involves data, charts, or an interactive page.
- Use a normal Markdown table when the user asks for a table; return it directly and do not create an artifact.
- Use Mermaid when labeled nodes and edges fully explain a static structure; return a normal fenced Mermaid block and no artifact. Use HTML for dynamics, spatial motion, adjustable inputs, and other visuals that benefit from direct interaction.
- In user-facing prose, describe only what the visual helps the user see or decide. Keep it concise and do not repeat information already clear from the visual. Never announce this skill, HTML, scripts, local files, or implementation details.

Good uses include:

- Explaining a system, process, hierarchy, timeline, or relationship
- Exploring “what happens when” through controls or simulation
- Comparing options or inspecting structured information
- Creating a mind map, flow diagram, chart, graph, map, UI mockup, or small interactive demo

Do not use it for decoration, a single fact, or a simple list.

## HTML artifact contract

### Fragment

1. Create one responsive, self-contained HTML fragment with inline CSS and optional inline JavaScript.
2. Do not include `<html>`, `<head>`, or `<body>`; the host supplies the document shell.
3. Write literal markup. Do not emit escaped HTML such as `<div class=\"card\">` or literal `\n` sequences.
4. Give the fragment root a unique ID and select it with `document.getElementById(...)`. Do not derive the root from `document.currentScript`.
5. Do not use external scripts, styles, fonts, images, or network requests. Data URLs are allowed.
6. Keep the artifact focused on the visual. Include only necessary labels, legends, values, controls, and accessible text alternatives; put explanations outside it.
7. Keep the artifact under 512 KB. Reduce precision, aggregate data, or remove unused fields when necessary.
8. Before publishing, check that JavaScript has no undefined identifiers, every queried element exists, the initial view is useful, and the primary interaction updates the visual.

### Theme and color

Use these host theme tokens so the artifact follows the current appearance:

   - `--clacky-bg`
   - `--clacky-surface`
   - `--clacky-text`
   - `--clacky-muted`
   - `--clacky-border`
   - `--clacky-accent`

- Make fills, strokes, text, borders, shadows, charts, and canvas colors theme-aware. Do not hardcode a light-only or dark-only palette.
- Use `--clacky-text` for essential labels and values, `--clacky-muted` for secondary context, `--clacky-surface` for the few bounded surfaces that are actually needed, and `--clacky-accent` for the primary measure or selected state.
- For multiple categories, derive restrained variants from the theme tokens and pair color with text, shape, or line style so meaning never depends on color alone.
- Keep large-area fills subtle. Use thin neutral structure and reserve the accent for information or interaction, not decoration.

## Composition

Choose the smallest composition that fits.

- Prefer useful interaction detail over permanent panels, toolbars, repeated legends, or long stacks. Add only requested controls and use one mechanism per state.
- Do not invent search, filter, reset, status, KPI, or summary cards to fill empty space.
- Put changing values beside their controls or directly on the visual. Treat maxima as ceilings, not targets.
- Keep presentation-only interaction local to the fragment. There is no host state or follow-up API, so the artifact must not depend on persistence or sending messages back to the agent.
- Make the first render useful before any input changes. Keep essential content and actions available without hover.

### Interactive explainers and simulations

- Use compact controls, one dominant visual, and at most one short selected-state detail.
- For a step-through, update one current visual. Do not add parameter controls, formulas, metric cards, or side-by-side steps unless requested.
- Animate meaningful transitions between states rather than adding decorative or looping motion. Honor `prefers-reduced-motion`.
- Show validation problems next to the relevant control and expose dynamic results with `aria-live="polite"`.

### UI mockups

- Use product and platform context already available in the conversation. Match the product's chrome, navigation, typography, colors, content density, and interaction patterns.
- Frame a component, dialog, small feature, or mobile screen as a compact product surface. Let a desktop window or full application page occupy the available width without wrapping it in another decorative card.
- Put app-wide navigation and pickers in the app chrome, and local controls in their component. Omit single-option pickers.
- Show realistic states instead of invented dashboards, filler cards, oversized icons, or fake screenshots.
- Keep product windows, cards, menus, and popovers opaque and layer overlays above the product content.

### Graphs, plots, and diagrams

- Use handwritten responsive SVG for charts, diagrams, and directly labeled values; use canvas only when the number of marks makes SVG impractical. External chart libraries are unavailable.
- Give a self-contained figure a concise visible title. Include labeled axes, units, and directly labeled important values. Add a legend only when multiple series cannot be labeled directly.
- Give every SVG or canvas a concise screen-reader summary using a role and accessible name, SVG `<title>`/`<desc>`, fallback text, or nearby visually hidden text.
- Size the visual from its actual container. Use a responsive `viewBox` for SVG and `ResizeObserver` when JavaScript must redraw based on width.
- Reserve room for the longest formatted label. At narrow widths reduce ticks or nonessential annotations rather than shrinking readable text or letting labels overlap.
- Prefer direct labels for simple charts. When a tooltip is necessary, support keyboard focus and touch as well as hover, and keep the selected value visible.
- For multiple series, toggle the corresponding line, marks, and legend state together. Keep observations, trends, and important values visible.
- For sequences or parallel work, use aligned lanes on one time axis. For distributions or multi-metric comparisons, use shared-scale facets or small multiples.
- Use inline geographic data for maps and project real coordinates correctly. Never guess or hand-draw geographic boundaries; use a schematic only when the user asks for one.

## Layout and accessibility

- Use semantic HTML, native controls, concise visible labels, and keyboard-accessible interactions.
- Fill the available width and support widths down to 320px. Stack side-by-side content when it no longer fits.
- Avoid fixed outer widths, horizontal overflow, viewport-height layouts, `position: fixed`, and unnecessary internal scrolling.
- The host clamps the published height to 240–720 pixels and hides overflow. Keep the composition within that range instead of relying on a tall scrolling canvas.
- At every supported width, text, controls, labels, and dynamic content must fit without overlap or clipping.
- Keep native tab order and focus styles. Use real `button`, `input`, `select`, and `textarea` elements instead of recreating controls with generic elements.
- On touch devices, provide non-overlapping effective targets around 44px while keeping visible icons and marks compact.
- Use visible text or an accessible label for icon-only actions. Prefer text labels and simple CSS shapes; authored inline SVG is appropriate for data marks and charts.

## Build and publish

1. Write the fragment to `/tmp/clacky-visualization-<%= session_id %>.html` with the `write` tool.
2. Choose a concise title and a height that fits the complete composition.
3. Run the bundled publisher:

```bash
ruby "<skill_dir>/publish.rb" --title "SHORT TITLE" --height 420 --delete-source "/tmp/clacky-visualization-<%= session_id %>.html"
```

- `--height` is optional and is clamped to 240–720 pixels.
- The publisher prints one `visualize{...}` content reference.
- Copy that reference **exactly and without a code fence** into the final response.
- Include at most one concise conclusion or explanation; the artifact must not be the only answer.
- Never paste the HTML source into the response.
