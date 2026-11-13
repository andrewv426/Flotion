import MCP

private func object(_ properties: [String: Value], required: [String] = []) -> Value {
    .object([
        "type": "object",
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
        "additionalProperties": false,
    ])
}

private func string(_ description: String) -> Value { ["type": "string", "description": .string(description)] }
private func integer(_ description: String) -> Value { ["type": "integer", "description": .string(description)] }
private func number(_ description: String) -> Value { ["type": "number", "description": .string(description)] }
private func boolean(_ description: String) -> Value { ["type": "boolean", "description": .string(description)] }

private let markdownNote = """
    Markdown supports headings (#, ##, ###), paragraphs, bulleted and numbered lists (nest by indenting), \
    to-dos (- [ ] / - [x]), quotes (>), fenced code blocks, dividers (---), and inline bold, italic, \
    strikethrough, code and links. Link to another page with [Title](flotion://page/<page_id>) on its own line.
    """

private let diagramGuide = """
    Two formats:
    • "steps" — a slideshow. Pass `steps`: an array of {title?, caption?, svg | html}. Flotion supplies the frame, \
    the transition between steps, progress dots and previous / next / play controls. Give every step an SVG with the \
    same viewBox and keep shared elements in the same place, so the viewer sees things appear, move or change from \
    step to step. Best for processes, sequences, protocols and before/after comparisons.
    • "html" — one self-contained HTML document (inline CSS, JS and SVG) for a bespoke animation. It runs in a \
    sandbox with no network access.
    Rules for both: everything must be inline — no external scripts, stylesheets, fonts or images. Use the theme \
    variables so the diagram matches light and dark mode: --fl-bg, --fl-text, --fl-muted, --fl-accent, --fl-border, \
    --fl-font. Leave the background transparent. Design for a width of about 700 points; `height` is in points \
    (120–1200, default 360).
    """

private let stepsSchema: Value = [
    "type": "array",
    "description": "For format \"steps\": the slides, in order.",
    "items": [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Short heading shown above the step."],
            "caption": ["type": "string", "description": "One or two sentences explaining the step."],
            "svg": ["type": "string", "description": "A complete <svg> element for this step."],
            "html": ["type": "string", "description": "An HTML fragment for this step (alternative to svg)."],
        ],
    ],
]

public extension FlotionTools {
    static let definitions: [Tool] = [
        Tool(name: "search_pages",
             description: "Full-text search across page titles and content. Returns matching pages with a snippet.",
             inputSchema: object(["query": string("Words to search for."), "limit": integer("Maximum results (default 10).")], required: ["query"]),
             annotations: .init(readOnlyHint: true)),
        Tool(name: "list_pages",
             description: "List the pages directly under a parent page, or the top-level pages when parent_id is omitted.",
             inputSchema: object(["parent_id": string("Page whose sub-pages to list.")]),
             annotations: .init(readOnlyHint: true)),
        Tool(name: "get_page",
             description: "Read a page as Markdown, followed by an outline of its blocks with the block ids needed for edits.",
             inputSchema: object(["page_id": string("The page to read."),
                                  "include_block_ids": boolean("Include the block outline (default true).")], required: ["page_id"]),
             annotations: .init(readOnlyHint: true)),
        Tool(name: "create_page",
             description: "Create a page, optionally with Markdown content. " + markdownNote,
             inputSchema: object(["title": string("Page title."), "parent_id": string("Parent page; omit for a top-level page."),
                                  "icon": string("A single emoji shown beside the title."), "markdown": string("Initial content.")], required: ["title"])),
        Tool(name: "update_page",
             description: "Rename a page, change its icon, or move it under another page. Does not change content.",
             inputSchema: object(["page_id": string("The page to change."), "title": string("New title."),
                                  "icon": string("New emoji icon; empty string removes it."),
                                  "parent_id": string("New parent page; empty string moves it to the top level.")], required: ["page_id"])),
        Tool(name: "append_blocks",
             description: "Insert Markdown content into a page: at the end by default, after a given block, or at the start. " + markdownNote,
             inputSchema: object(["page_id": string("The page to add to."), "markdown": string("Content to insert."),
                                  "after_block_id": string("Insert directly after this block."),
                                  "at_start": boolean("Insert at the top of the page.")], required: ["page_id", "markdown"])),
        Tool(name: "update_block",
             description: "Replace one block with new Markdown. If the Markdown has several blocks, the first replaces the block and the rest follow it.",
             inputSchema: object(["block_id": string("The block to replace (from get_page)."), "markdown": string("Replacement content.")], required: ["block_id", "markdown"])),
        Tool(name: "delete_block",
             description: "Remove one block from its page.",
             inputSchema: object(["block_id": string("The block to remove (from get_page).")], required: ["block_id"]),
             annotations: .init(destructiveHint: true)),
        Tool(name: "archive_page",
             description: "Move a page and its sub-pages to the Trash. The user can restore it; nothing is permanently deleted.",
             inputSchema: object(["page_id": string("The page to move to the Trash.")], required: ["page_id"]),
             annotations: .init(destructiveHint: true)),
        Tool(name: "create_diagram",
             description: "Create an animated or step-by-step diagram and insert it into a page as a block. " + diagramGuide,
             inputSchema: object(["page_id": string("The page to insert into."), "title": string("Diagram title."),
                                  "format": ["type": "string", "enum": ["steps", "html"], "description": "Which format the content is in."],
                                  "steps": stepsSchema, "html": string("For format \"html\": the full HTML document."),
                                  "after_block_id": string("Insert directly after this block; otherwise at the end."),
                                  "height": number("Display height in points.")], required: ["page_id", "title", "format"])),
        Tool(name: "get_diagram",
             description: "Read a diagram block's title, format and source so it can be revised.",
             inputSchema: object(["block_id": string("The diagram block (from get_page).")], required: ["block_id"]),
             annotations: .init(readOnlyHint: true)),
        Tool(name: "update_diagram",
             description: "Change an existing diagram's title, content or height. " + diagramGuide,
             inputSchema: object(["block_id": string("The diagram block to change."), "title": string("New title."),
                                  "format": ["type": "string", "enum": ["steps", "html"], "description": "Only when switching format."],
                                  "steps": stepsSchema, "html": string("Replacement HTML document."),
                                  "height": number("Display height in points.")], required: ["block_id"])),
    ]
}
