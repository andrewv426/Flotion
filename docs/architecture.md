# Architecture

One rule shapes the layout: **all data logic lives in `FlotionCore`, and everything else goes through it.** The app, the MCP server and the in-app assistant are three clients of the same code, so anything the UI can do to a page an LLM can do through the same path.

The in-app assistant is not a second integration. It is the user's own Claude Code, started as a subprocess with only `flotion-mcp` attached: the same server external clients use.

```mermaid
flowchart TB
    subgraph app["Flotion.app — SwiftUI + AppKit"]
        sidebar["Sidebar<br/>page tree, Trash"]
        editor["Editor<br/>NSTableView, one NSTextView per block"]
        diagram["Diagram blocks<br/>sandboxed WKWebView, no network"]
        panel["Assistant panel<br/>and Edit with AI"]
    end

    cli["claude CLI<br/>the user's own install,<br/>signed in with their subscription"]
    anthropic(["Anthropic"])
    external["External MCP clients<br/>Claude Code, Claude Desktop, others"]
    mcp["flotion-mcp<br/>Swift CLI inside the .app<br/>pages · blocks · search · diagrams"]

    subgraph kit["FlotionKit package"]
        editorlib["FlotionEditor<br/>view-free editing rules"]
        ai["FlotionAI<br/>provider, stream parser, chat session"]
        core["FlotionCore<br/>models · stores · Markdown · search<br/>change log · diagram validation"]
    end

    db[("flotion.sqlite<br/>WAL mode")]

    editor --> editorlib
    panel --> ai
    ai -- "spawns · stream-json over pipes" --> cli
    cli -- HTTPS --> anthropic
    cli -- "MCP over stdio" --> mcp
    external -- "MCP over stdio" --> mcp
    sidebar --> core
    editorlib --> core
    diagram --> core
    mcp --> core
    core --> db
    mcp -. "Darwin notification:<br/>workspace changed" .-> app
```

## Processes

| Process | Started by | Talks to |
|---|---|---|
| `Flotion.app` | the user | the database, through `FlotionCore` |
| `flotion-mcp` | an MCP client (Claude Code, or the in-app `claude`) | the same database file; pings the app after each write |
| `claude` | the app, one per request | Anthropic over HTTPS; `flotion-mcp` over stdio |

The app and `flotion-mcp` share one SQLite file in WAL mode. After a write, `flotion-mcp` posts a Darwin notification and the app reloads the changed page, merging block by block so text the user is typing is never overwritten.

## Targets

| Target | Depends on | Holds |
|---|---|---|
| `FlotionCore` | GRDB, swift-markdown | Schema and migrations, page and block stores, full-text search, Markdown codec, change log and undo, diagram validation and HTML template |
| `FlotionMCP` | Core, MCP Swift SDK | The 12 tools, their schemas, and a blocking stdio transport |
| `flotion-mcp` | FlotionMCP | The executable: three lines |
| `FlotionEditor` | Core | `EditorState`: split, merge, indent, reorder, Markdown shortcuts, undo, merging remote changes |
| `FlotionAI` | Core | `AIProvider`, the Claude Code provider, stream-json parser, chat session, prompts |
| `App/` | Core, Editor, AI | Views only |

## Data model

| Table | Purpose |
|---|---|
| `pages` | Tree of pages; `archived_at` is the Trash |
| `blocks` | Flat ordered list per page with a `depth` column. Plain text lives in `plain`; `text` holds JSON runs only when a block has formatting |
| `diagrams` | Diagram source: Flow text, or for the older formats a full HTML document or a JSON array of steps |
| `change_log` | Every write made by an AI or MCP client, with before and after, grouped into turns so a turn can be undone |
| `blocks_fts`, `pages_fts` | FTS5 indexes kept in sync by triggers |

## How the assistant is contained

The app never signs in and never sees a credential. It runs the unmodified `claude` binary with:

- `--tools ""`: no built-in tools, so no shell and no file access
- `--strict-mcp-config` with one server, `flotion-mcp`
- `--setting-sources ""` and `--disable-slash-commands`: none of the user's coding setup
- `--permission-mode dontAsk` with only `mcp__flotion` allowed
- an empty working directory, and an environment with no API keys

`FlotionAITests` asserts each of these flags.

## How a diagram is drawn

A diagram is written in Flow, a line-per-statement language with no coordinates, colours or sizes: nodes, arrows, groups, and steps that say what changes. Everything between the source and the picture runs in `FlotionCore`, so the MCP server can reject a bad diagram at the tool call and the app knows a diagram's height before any web view exists.

```mermaid
flowchart LR
    source["Flow source<br/>(stored in diagrams)"] --> parser["FlowParser<br/>model, or problems by line"]
    parser --> states["states()<br/>the picture at each step"]
    parser --> layout["FlowLayout<br/>positions, arrow routes"]
    states --> scene["FlowScene<br/>resolved JSON"]
    layout --> scene
    scene --> player["Player in the web view<br/>switches between states"]
```

| Stage | What it decides |
|---|---|
| `FlowParser` | What the source means. Every problem is reported with its line and, where it can guess, the fix |
| `FlowDiagram.states()` | What is visible, labelled, coloured and dimmed at each step. `tag`, `mark`, `set`, `hide` and `show` carry forward; `send` and `focus` last one step |
| `FlowLayout` | Where things go, once, over everything the diagram ever shows, so nothing moves between steps. Layered: rank by longest path, order to avoid crossings, then align so chains are straight. Arrows run outline to outline |
| `FlowScene` | The SVG paths and per-step states, as JSON |
| The player (`DiagramTemplate`) | Nothing. It draws the scene and moves between states with CSS transitions |

## How diagrams are contained

A Flow diagram is data, not code: its labels reach the page only as text, and the script that draws it is Flotion's own. The older `html` format (still available as an escape hatch) and `steps` format (still rendered, no longer created) carry LLM-authored markup, so every diagram document is treated as untrusted:

1. `DiagramValidator` rejects Flow source with mistakes, and external references in HTML, before anything is stored, which also gives the model a useful error.
2. `DiagramTemplate` adds a Content-Security-Policy of `default-src 'none'` to every document.
3. The web view has a content rule that blocks every network request, a non-persistent data store, and refuses navigation.

The in-app self-test checks that `fetch()` and a remote image both fail inside a diagram.
