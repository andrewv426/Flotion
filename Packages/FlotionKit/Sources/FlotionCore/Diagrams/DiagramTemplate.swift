import Foundation

/// Turns a stored diagram into the HTML document the app's sandboxed web view loads.
/// Every document gets a strict Content-Security-Policy and the Flotion theme variables;
/// a steps diagram also gets the slideshow frame, transitions and controls.
public enum DiagramTemplate {
    /// No network of any kind: only inline styles and scripts, and data: images and fonts.
    public static let contentSecurityPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:"

    static let head = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>
        :root {
          color-scheme: light dark;
          --fl-bg: #FFFFFF; --fl-text: #37352F; --fl-muted: #787774; --fl-accent: #2383E2;
          --fl-border: rgba(55,53,47,0.16); --fl-soft: rgba(55,53,47,0.06);
          --fl-font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        }
        @media (prefers-color-scheme: dark) {
          :root { --fl-bg: #191919; --fl-text: rgba(255,255,255,0.81); --fl-muted: rgba(255,255,255,0.46);
                  --fl-border: rgba(255,255,255,0.16); --fl-soft: rgba(255,255,255,0.06); }
        }
        html, body { margin: 0; height: 100%; background: transparent; color: var(--fl-text);
                     font-family: var(--fl-font); font-size: 14px; -webkit-font-smoothing: antialiased; }
        </style>
        """

    public static func document(for diagram: Diagram) -> String {
        switch diagram.format {
        case .html: htmlDocument(diagram.source)
        case .steps: stepsDocument((try? decodeJSON([DiagramStep].self, diagram.source)) ?? [])
        }
    }

    /// A free-form document keeps its own structure; the policy and theme go first in its head.
    static func htmlDocument(_ source: String) -> String {
        if let range = source.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return source.replacingCharacters(in: range, with: source[range] + head)
        }
        if let range = source.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return source.replacingCharacters(in: range, with: source[range] + "<head>\(head)</head>")
        }
        return "<!doctype html><html><head>\(head)</head><body>\(source)</body></html>"
    }

    static func stepsDocument(_ steps: [DiagramStep]) -> String {
        let sections = steps.enumerated().map { index, step in
            """
            <section class="step\(index == 0 ? " on" : "")">
              <div class="stage">\(step.svg ?? step.html ?? "")</div>
              <div class="words">
                \(step.title.map { "<h2>\(escape($0))</h2>" } ?? "")
                \(step.caption.map { "<p>\(escape($0))</p>" } ?? "")
              </div>
            </section>
            """
        }.joined(separator: "\n")
        let dots = steps.indices.map { "<button class=\"dot\" data-i=\"\($0)\" aria-label=\"Step \($0 + 1)\"></button>" }.joined()

        return """
            <!doctype html><html><head>\(head)
            <style>
            body { display: flex; flex-direction: column; }
            .deck { position: relative; flex: 1; min-height: 0; }
            .step { position: absolute; inset: 0; display: flex; flex-direction: column; opacity: 0;
                    transition: opacity .32s ease; pointer-events: none; }
            .step.on { opacity: 1; pointer-events: auto; }
            .stage { flex: 1; min-height: 0; display: flex; align-items: center; justify-content: center; padding: 8px 16px 0; }
            .stage > svg { width: 100%; height: 100%; }
            .words { padding: 6px 20px 2px; text-align: center; min-height: 44px; }
            .words h2 { margin: 0 0 2px; font-size: 15px; font-weight: 600; }
            .words p { margin: 0; color: var(--fl-muted); font-size: 13px; line-height: 1.45; }
            .bar { display: flex; align-items: center; justify-content: center; gap: 10px; padding: 6px 12px 10px; }
            .bar button { all: unset; cursor: pointer; }
            .bar .nav { width: 26px; height: 26px; border-radius: 5px; display: grid; place-items: center; color: var(--fl-muted); font-size: 15px; }
            .bar .nav:hover { background: var(--fl-soft); color: var(--fl-text); }
            .bar .nav[disabled] { opacity: .3; cursor: default; }
            .dots { display: flex; gap: 6px; }
            .bar .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--fl-border); transition: background .2s, transform .2s; }
            .bar .dot.on { background: var(--fl-accent); transform: scale(1.25); }
            .count { color: var(--fl-muted); font-size: 12px; font-variant-numeric: tabular-nums; min-width: 38px; text-align: center; }
            @media (prefers-reduced-motion: reduce) { .step { transition: none; } }
            </style></head>
            <body>
            <div class="deck">\(sections)</div>
            <div class="bar">
              <button class="nav" id="prev" aria-label="Previous step">‹</button>
              <div class="dots">\(dots)</div>
              <button class="nav" id="next" aria-label="Next step">›</button>
              <button class="nav" id="play" aria-label="Play">▶</button>
              <span class="count" id="count"></span>
            </div>
            <script>
            (function () {
              var steps = document.querySelectorAll('.step'), dots = document.querySelectorAll('.dot');
              var prev = document.getElementById('prev'), next = document.getElementById('next');
              var play = document.getElementById('play'), count = document.getElementById('count');
              var index = 0, timer = null;
              function go(i) {
                index = Math.max(0, Math.min(steps.length - 1, i));
                steps.forEach(function (s, k) { s.classList.toggle('on', k === index); });
                dots.forEach(function (d, k) { d.classList.toggle('on', k === index); });
                prev.disabled = index === 0; next.disabled = index === steps.length - 1;
                count.textContent = (index + 1) + ' / ' + steps.length;
              }
              function stop() { clearInterval(timer); timer = null; play.textContent = '▶'; }
              function start() {
                if (index === steps.length - 1) go(0);
                play.textContent = '❚❚';
                timer = setInterval(function () { if (index >= steps.length - 1) stop(); else go(index + 1); }, 2200);
              }
              prev.onclick = function () { stop(); go(index - 1); };
              next.onclick = function () { stop(); go(index + 1); };
              play.onclick = function () { timer ? stop() : start(); };
              dots.forEach(function (d) { d.onclick = function () { stop(); go(+d.dataset.i); }; });
              document.addEventListener('keydown', function (e) {
                if (e.key === 'ArrowRight') { stop(); go(index + 1); }
                if (e.key === 'ArrowLeft') { stop(); go(index - 1); }
              });
              window.flotion = { count: steps.length, go: go, index: function () { return index; } };
              go(0);
            })();
            </script>
            </body></html>
            """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
