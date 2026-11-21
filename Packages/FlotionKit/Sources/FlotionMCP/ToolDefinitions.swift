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
    Diagrams are written in Flow, a small text language. You say what exists and what changes at each step; \
    Flotion places everything, draws the arrows and animates between steps. There are no coordinates, colours or sizes.

    flow right | down                          direction (default right)
    id: Label {shape: box|pill|circle|diamond|database}
    a -> b: label {style: dashed}              an edge (`->`, `<-`, `<->`, or `--`); label and style are optional
    group id "Title" {                         a shaded region around the nodes declared inside it
      ...nodes...
    }
    step "Title": caption                      every line after this belongs to the step
      send a -> b: label                       a message travels between a and b, in that direction
      focus a, b                               dim everything else
      tag a, b: status                         a short status line inside the node
      mark a: accent|good|warn|bad|muted|none  colour by meaning
      set a: New label
      hide a, b
      show a, b
      x: New node                              a node or edge declared in a step appears at that step

    Rules: ids use letters, digits, _ and -. Declare a node before using it. Edges support `->` (forward), `<-` \
    (backward, keeping the left node earlier in layout), `<->` (bidirectional) and `--` (undirected), and can be \
    chained (`a -> b <- c`). `show` and `hide` accept any of the four edge operators. `send` always uses `->` over \
    any declared edge between the two nodes, temporarily pointing the arrowhead in the message direction for that \
    step. `send` and `focus` last for their step only; tag, mark, set, hide and show carry on until changed. `# ` \
    starts a comment. A diagram without steps is a still picture. Keep labels to a few words and put the explanation \
    in step captions; 3 to 8 nodes and 3 to 6 steps reads best.

    Example:
    flow right
    client: Client
    server: Server {shape: database}
    client -> server
    step "SYN": The client asks to open a connection.
      send client -> server: SYN
      tag client: SYN sent
    step "SYN-ACK": The server acknowledges and asks back.
      send server -> client: SYN-ACK
      tag server: SYN received
    step "ACK": The connection is open.
      send client -> server: ACK
      mark client, server: good

    If the source has mistakes the call fails with `line N: problem` for each one and nothing is saved: fix those \
    lines and call again.
    """

private let htmlNote = """
    Only when Flow cannot express the visual: one self-contained HTML document (inline CSS, JS and SVG) that runs \
    in a sandbox with no network. Use the theme variables --fl-bg, --fl-text, --fl-muted, --fl-accent, --fl-border, \
    --fl-font, leave the background transparent and set `height`.
    """

private let editsSchema: Value = [
    "type": "array",
    "description": "Small changes to a Flow diagram, applied in order. Each `old` must match the current source exactly once.",
    "items": [
        "type": "object",
        "properties": [
            "old": ["type": "string", "description": "Exact text in the current source, such as one whole line."],
            "new": ["type": "string", "description": "What replaces it; an empty string deletes it."],
        ],
        "required": ["old", "new"],
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
             description: "Create a diagram, optionally animated step by step, and insert it into a page as a block. " + diagramGuide,
             inputSchema: object(["page_id": string("The page to insert into."), "title": string("Diagram title."),
                                  "source": string("The diagram in Flow."),
                                  "html": string(htmlNote),
                                  "after_block_id": string("Insert directly after this block; otherwise at the end."),
                                  "height": number("For `html` only: display height in points (120–1200, default 360). Flow diagrams size themselves.")],
                          required: ["page_id", "title"])),
        Tool(name: "get_diagram",
             description: "Read a diagram block's title, format and source so it can be revised.",
             inputSchema: object(["block_id": string("The diagram block (from get_page).")], required: ["block_id"]),
             annotations: .init(readOnlyHint: true)),
        Tool(name: "update_diagram",
             description: "Change an existing diagram. For a small change to a Flow diagram pass `edits`; to rewrite it pass a whole new `source`. " + diagramGuide,
             inputSchema: object(["block_id": string("The diagram block to change."), "title": string("New title."),
                                  "source": string("The whole diagram in Flow, replacing the current one."),
                                  "edits": editsSchema,
                                  "html": string(htmlNote),
                                  "height": number("For `html` only: display height in points.")], required: ["block_id"])),
    ]
}
