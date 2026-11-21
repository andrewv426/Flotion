import Foundation

/// Turns a stored diagram into the HTML document the app's sandboxed web view loads.
/// Every document gets a strict Content-Security-Policy and the Flotion theme variables.
/// A Flow diagram is drawn by Flotion's own player from a resolved scene, so none of its
/// content runs as code; the older steps and html formats carry author-written markup.
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
          --fl-line: rgba(55,53,47,0.48); --fl-node-border: rgba(55,53,47,0.24); --fl-node: #FFFFFF; --fl-group: #F7F7F5;
          --fl-good: #448361; --fl-warn: #D9730D; --fl-bad: #D44C47;
          --fl-font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        }
        @media (prefers-color-scheme: dark) {
          :root { --fl-bg: #191919; --fl-text: rgba(255,255,255,0.81); --fl-muted: rgba(255,255,255,0.46);
                  --fl-border: rgba(255,255,255,0.16); --fl-soft: rgba(255,255,255,0.06);
                  --fl-line: rgba(255,255,255,0.42); --fl-node-border: rgba(255,255,255,0.20); --fl-node: #262626; --fl-group: #202020;
                  --fl-accent: #4A9FF0; --fl-good: #5BB98C; --fl-warn: #F0A04B; --fl-bad: #F2766F; }
        }
        html, body { margin: 0; height: 100%; background: transparent; color: var(--fl-text);
                     font-family: var(--fl-font); font-size: 14px; -webkit-font-smoothing: antialiased; }
        </style>
        """

    public static func document(for diagram: Diagram) -> String {
        switch diagram.format {
        case .html: htmlDocument(diagram.source)
        case .steps: stepsDocument((try? decodeJSON([DiagramStep].self, diagram.source)) ?? [])
        case .flow: (try? FlowScene(source: diagram.source)).map(flowDocument) ?? htmlDocument("<p style=\"color:var(--fl-muted)\">This diagram could not be read.</p>")
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

    // MARK: Flow

    /// The scene travels as JSON in a data block. Text from it only ever reaches the page through
    /// `textContent`, and `<` is escaped so no label can close the block early.
    public static func flowDocument(_ scene: FlowScene) -> String {
        let json = ((try? encodeJSON(scene)) ?? "{}").replacingOccurrences(of: "<", with: "\\u003c")
        return """
            <!doctype html><html><head>\(head)<style>\(flowStyle)</style></head>
            <body>
            <div class="fig" id="fig" tabindex="0">
              <svg class="stage" id="stage" role="img"></svg>
              <div class="cap"><div class="cap-copy" id="caption"><div class="cap-title" id="cap-title"></div><div class="cap-text" id="cap-text"></div></div></div>
              <div class="controls">
                <button class="nav" id="prev" aria-label="Previous step"><svg viewBox="0 0 16 16"><path d="M10 3.5 5.5 8l4.5 4.5"/></svg></button>
                <div class="dots" id="dots"></div>
                <button class="nav" id="next" aria-label="Next step"><svg viewBox="0 0 16 16"><path d="M6 3.5 10.5 8 6 12.5"/></svg></button>
                <button class="nav play" id="play" aria-label="Play"><svg viewBox="0 0 16 16"><path id="play-icon" d=""/></svg></button>
              </div>
            </div>
            <script type="application/json" id="scene">\(json)</script>
            <script>\(flowPlayer)</script>
            </body></html>
            """
    }

    static let flowStyle = #"""
        body { overflow: hidden; }
        .fig { outline: none; --motion-ease: cubic-bezier(.2,.7,.2,1); }
        .stage { display: block; margin: 0 auto; width: 100%; height: auto; overflow: visible; }
        .stage.no-anim, .stage.no-anim * { transition: none !important; }

        .group rect { fill: var(--fl-group); }
        .group text { fill: var(--fl-muted); font-size: 12px; font-weight: 500; }
        .group, .node, .edge, .elabel { transition: opacity .26s var(--motion-ease); }
        .dim { opacity: .28; }
        .off { opacity: 0; }

        .node .inner { transform-box: fill-box; transform-origin: center; transition: transform .32s var(--motion-ease); }
        .node.off .inner { transform: translateY(5px) scale(.96); }
        .shape { fill: var(--fl-node); stroke: var(--fl-node-border); stroke-width: 1.25; transition: fill .26s ease, stroke .26s ease; }
        .ring { fill: none; stroke: var(--tone, var(--fl-accent)); stroke-width: 1.5; opacity: 0; pointer-events: none;
                transform-box: fill-box; transform-origin: center; }
        .label { fill: var(--fl-text); font-size: 14px; font-weight: 500; transition: transform .26s var(--motion-ease), fill .26s ease; }
        .tag { fill: var(--fl-muted); font-size: 12px; transition: fill .26s ease; }
        .node[data-tone="accent"] { --tone: var(--fl-accent); }
        .node[data-tone="good"] { --tone: var(--fl-good); }
        .node[data-tone="warn"] { --tone: var(--fl-warn); }
        .node[data-tone="bad"] { --tone: var(--fl-bad); }
        .node[data-tone]:not([data-tone="muted"]) .shape { stroke: var(--tone); fill: color-mix(in srgb, var(--tone) 10%, var(--fl-node)); }
        .node[data-tone]:not([data-tone="muted"]) .tag { fill: var(--tone); }
        .node[data-tone="muted"] .shape { stroke-dasharray: 3 3; }
        .node[data-tone="muted"] .label { fill: var(--fl-muted); }

        .line { fill: none; stroke: var(--fl-line); stroke-width: 1.25; stroke-linecap: round;
                transition: stroke .18s ease, stroke-width .18s ease, stroke-dashoffset .32s ease; }
        .edge.solid .line { stroke-dasharray: 1; stroke-dashoffset: 0; }
        .edge.solid.off .line { stroke-dashoffset: 1; }
        .edge.dashed .line { stroke-dasharray: 4 4; }
        .head { fill: var(--fl-line); stroke: var(--fl-line); stroke-width: 1; stroke-linejoin: round;
                transition: fill .25s ease, stroke .25s ease; }
        .direction { opacity: 0; transition: opacity .26s var(--motion-ease); }
        .edge.at-hi .direction.hi, .edge.at-lo .direction.lo, .edge.at-both .direction.both, .edge.at-none .direction.none { opacity: 1; }
        .edge.live .line { stroke: var(--fl-accent); stroke-width: 1.6; }
        .edge.live .head { fill: var(--fl-accent); stroke: var(--fl-accent); }
        .elabel { fill: var(--fl-muted); font-size: 12.5px; font-weight: 500; paint-order: stroke; stroke: var(--fl-bg);
                  stroke-width: 6px; stroke-linejoin: round; }
        .elabel.in-group { stroke: var(--fl-group); }
        .elabel.live { fill: var(--fl-accent); }
        .token { fill: var(--fl-accent); stroke: var(--fl-node); stroke-width: 1.5; }
        .message-trail { fill: none; stroke: var(--fl-accent); stroke-linecap: round; pointer-events: none; }

        .cap { position: relative; height: 66px; text-align: center; overflow: hidden; }
        .cap-copy { position: absolute; inset: 8px 16px 0; }
        .cap-copy[aria-hidden] { pointer-events: none; user-select: none; }
        .cap-title { font-size: 14px; line-height: 18px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .cap-text { margin-top: 2px; font-size: 13px; line-height: 18px; color: var(--fl-muted);
                    display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; }
        .controls { display: flex; align-items: center; justify-content: center; gap: 8px; height: 34px; }
        .controls button { all: unset; cursor: pointer; }
        .controls .nav { width: 24px; height: 24px; border-radius: 5px; display: grid; place-items: center; color: var(--fl-muted);
                         opacity: 0; transition: opacity .18s ease, background .12s ease; }
        .controls .nav svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
        .controls .nav.play svg { fill: currentColor; stroke: none; }
        .controls .nav:hover { background: var(--fl-soft); color: var(--fl-text); }
        .controls .nav[disabled] { visibility: hidden; }
        .fig:hover .controls .nav, .fig:focus-within .controls .nav { opacity: 1; }
        .dots { display: flex; gap: 5px; align-items: center; }
        .controls .dot { width: 6px; height: 6px; border-radius: 3px; background: var(--fl-node-border); transition: width .16s ease, background .16s ease; }
        .controls .dot.on { width: 16px; background: var(--fl-accent); }
        .static .cap, .static .controls { display: none; }
        """#

    /// Draws a persistent scene and animates its changes as the player moves between steps.
    static let flowPlayer = #"""
        (function () {
          const S = JSON.parse(document.getElementById('scene').textContent);
          const NS = 'http://www.w3.org/2000/svg';
          const el = (name, attrs, text) => {
            const e = document.createElementNS(NS, name);
            for (const k in attrs) e.setAttribute(k, attrs[k]);
            if (text != null) e.textContent = text;
            return e;
          };
          const $ = id => document.getElementById(id);
          const fig = $('fig'), stage = $('stage');
          const caption = $('caption'), captionTitle = $('cap-title'), captionText = $('cap-text');
          // A CSS cubic-bezier evaluated in script, for motion driven frame by frame.
          const bezier = (x1, y1, x2, y2) => x => {
            const at = (a, b, s) => 3 * a * (1 - s) * (1 - s) * s + 3 * b * (1 - s) * s * s + s * s * s;
            let lo = 0, hi = 1;
            for (let k = 0; k < 24; k++) { const s = (lo + hi) / 2; if (at(x1, x2, s) < x) lo = s; else hi = s; }
            return at(y1, y2, (lo + hi) / 2);
          };
          // Motion tokens: every duration (ms), easing and size the player animates with.
          const M = {
            ease: 'cubic-bezier(.2,.7,.2,1)',
            travel: bezier(.3, .1, .25, 1), // launches briskly, settles gently into the receiver
            // A damped spring's impulse: up to the peak, a small undershoot, back to rest.
            spring: 'linear(' + Array.from({ length: 17 }, (_, k) => (Math.exp(-k / 4) * Math.sin(Math.PI * k / 8) / .4453).toFixed(3)) + ')',
            leadIn: 180, gap: 160, travelMin: 600, travelMax: 1000, travelPerPx: 2.8,
            dot: 4.5, grow: .1, absorb: .12, absorbR: 2,
            trailWindow: 90, trailMax: 36, trailShare: .3,
            trail: [[1.5, .2, 1], [2.5, .4, .62], [3.5, .65, .3]], // width, opacity, share of the tail
            pulse: 440, pulseScale: 1.12, arriveOpacity: .55, changeOpacity: .28,
            emit: 300, emitOpacity: .25, emitScale: 1.05,
            bump: 360, bumpScale: 1.035,
            text: 260, captionOut: 180, captionIn: 260, tokenFade: 90,
            autoplay: 2300, afterJourney: 1000,
          };
          stage.setAttribute('viewBox', [S.x, S.y, S.w, S.h].join(' '));
          stage.style.maxWidth = S.w + 'px';
          if (!S.stepped) fig.classList.add('static');
          const layer = () => stage.appendChild(el('g', {}));
          const gGroups = layer(), gEdges = layer(), gLabels = layer(), gNodes = layer(), gTokens = layer();

          const groups = S.groups.map(g => {
            const e = gGroups.appendChild(el('g', { class: 'group' }));
            if (g.w) e.append(el('rect', { x: g.x, y: g.y, width: g.w, height: g.h, rx: 12 }), el('text', { x: g.x + 14, y: g.y + 20 }, g.title));
            return e;
          });
          const edges = S.edges.map(d => {
            const e = gEdges.appendChild(el('g', { class: 'edge ' + (d.solid ? 'solid' : 'dashed') }));
            const direction = (side, linePath, headPaths) => {
              const group = e.appendChild(el('g', { class: 'direction ' + side }));
              const line = group.appendChild(el('path', { class: 'line', d: linePath }));
              if (d.solid) line.setAttribute('pathLength', 1);
              for (const headPath of headPaths) group.appendChild(el('path', { class: 'head', d: headPath }));
              return line;
            };
            const hi = direction('hi', d.lineHi, [d.headHi]), lo = direction('lo', d.lineLo, [d.headLo]);
            direction('both', d.lineBoth, [d.headHi, d.headLo]);
            direction('none', d.lineNone, []);
            const label = gLabels.appendChild(el('text', { class: 'elabel' + (d.inGroup ? ' in-group' : ''), x: d.lx, y: d.ly, dy: '.35em', 'text-anchor': d.anchor }));
            return { e, hi, lo, label };
          });
          const nodes = S.nodes.map(d => {
            const e = gNodes.appendChild(el('g', { class: 'node', transform: 'translate(' + d.x + ',' + d.y + ')' }));
            const inner = e.appendChild(el('g', { class: 'inner' }));
            const ring = el('path', { class: 'ring', d: d.d });
            const label = el('text', { class: 'label', 'text-anchor': 'middle', dy: '.35em', y: d.sink });
            const tag = el('text', { class: 'tag', 'text-anchor': 'middle', dy: '.35em', y: d.sink + 11 });
            const shape = el('path', { class: 'shape', d: d.d });
            inner.append(shape, ring, label, tag);
            return { e, inner, shape, ring, label, tag, x: d.x, y: d.y };
          });
          const dots = S.steps.map((_, i) => {
            const dot = $('dots').appendChild(document.createElement('button'));
            dot.className = 'dot';
            dot.setAttribute('aria-label', 'Step ' + (i + 1));
            dot.onclick = () => seek(i);
            return dot;
          });

          let index = 0, activeTokens = null, timer = null, captionMotion, transitionDuration = 0;
          const textMotions = new WeakMap();
          const pulses = new WeakMap();

          function updateText(e, text, animate, offset) {
            if (e.textContent === text) return;
            textMotions.get(e)?.cancel();
            e.textContent = text;
            if (animate && text) {
              // Fill and halo fade rather than opacity, which an edge label's dim and off states own.
              textMotions.set(e, e.animate([{ translate: '0 ' + offset + 'px', fillOpacity: 0, strokeOpacity: 0 },
                                            { translate: '0 0', fillOpacity: 1, strokeOpacity: 1 }], { duration: M.text, easing: M.ease }));
            }
          }

          function updateCaption(step, animate, direction) {
            if (captionTitle.textContent === step.title && captionText.textContent === step.caption) return;
            if (animate) {
              const current = captionMotion?.playState === 'running' ? getComputedStyle(caption) : null;
              const opacity = current ? Number(current.opacity) : 1;
              if (opacity > .25 && (captionTitle.textContent || captionText.textContent)) {
                const outgoing = caption.cloneNode(true);
                outgoing.removeAttribute('id');
                outgoing.querySelectorAll('[id]').forEach(e => e.removeAttribute('id'));
                outgoing.setAttribute('aria-hidden', 'true');
                caption.before(outgoing);
                outgoing.animate([{ opacity, translate: current?.translate ?? 'none' },
                                  { opacity: 0, translate: '0 ' + (-direction * 8) + 'px' }],
                                 { duration: M.captionOut, easing: M.ease, fill: 'forwards' }).onfinish = () => outgoing.remove();
              }
            }
            captionMotion?.cancel();
            captionTitle.textContent = step.title;
            captionText.textContent = step.caption;
            if (animate) {
              captionMotion = caption.animate([{ opacity: .2, translate: '0 ' + (direction * 8) + 'px' },
                                               { opacity: 1, translate: '0 0' }], { duration: M.captionIn, easing: M.ease });
            }
          }

          // A ring that spreads outward from the outline and fades.
          function pulse(ring, opacity, duration = M.pulse, spread = M.pulseScale) {
            pulses.get(ring)?.cancel();
            pulses.set(ring, ring.animate([{ opacity, scale: '1', strokeWidth: '2px' }, { opacity: 0, scale: String(spread), strokeWidth: '1px' }],
                                          { duration, easing: M.ease }));
          }

          // The receiver gives a little as a message lands. `scale` composes with the transform of the off state.
          function bump(n) {
            pulses.get(n.inner)?.cancel();
            pulses.set(n.inner, n.inner.animate([{ scale: '1' }, { scale: String(M.bumpScale) }], { duration: M.bump, easing: M.spring }));
          }

          function setLive(edge, on) {
            edge.e.classList.toggle('live', on);
            edge.label.classList.toggle('live', on);
          }

          // The node whose outline is nearest a point: the sender, for the point where a message leaves.
          function nodeAt(p) {
            let best = null, bestDistance = Infinity;
            for (const n of nodes) {
              const b = n.box ??= n.shape.getBBox(), x = n.x + b.x, y = n.y + b.y;
              const distance = Math.hypot(Math.max(x - p.x, 0, p.x - x - b.width), Math.max(y - p.y, 0, p.y - y - b.height));
              if (distance < bestDistance) { best = n; bestDistance = distance; }
            }
            return best;
          }

          function updateNode(n, state, animate, direction, highlight) {
            const changed = n.label.textContent !== state.label || n.tag.textContent !== state.tag ||
                            (n.e.dataset.tone || null) !== (state.tone || null);
            if (state.tone) n.e.dataset.tone = state.tone; else delete n.e.dataset.tone;
            updateText(n.label, state.label, animate, direction * 4);
            updateText(n.tag, state.tag, animate, direction * 5);
            n.label.style.transform = state.tag ? 'translateY(-10px)' : '';
            if (animate && highlight && changed && state.on && !state.dim) pulse(n.ring, M.changeOpacity);
          }

          function go(i, animate) {
            const direction = i < index ? -1 : 1;
            index = i;
            const step = S.steps[index];
            transitionDuration = animate ? M.text : 0;
            updateCaption(step, animate, direction);
            if (activeTokens) {
              // Invalidating the group also cancels pending arrivals, so a rapid seek cannot
              // apply an old step's labels or status to the new picture.
              const outgoing = activeTokens;
              activeTokens = null;
              if (animate && outgoing.firstChild) {
                outgoing.animate([{ opacity: 1 }, { opacity: 0 }], M.tokenFade).onfinish = () => outgoing.remove();
              } else {
                outgoing.remove();
              }
            }
            nodes.forEach(n => { pulses.get(n.ring)?.cancel(); pulses.get(n.inner)?.cancel(); });
            step.groups.forEach((s, k) => { groups[k].classList.toggle('off', !s.on); groups[k].classList.toggle('dim', s.dim); });
            const receivers = new Set(animate ? step.sends.map(send => send.to) : []);
            const carriers = new Set(animate ? step.sends.map(send => send.edge) : []);
            step.nodes.forEach((s, k) => {
              const n = nodes[k];
              n.e.classList.toggle('off', !s.on);
              n.e.classList.toggle('dim', s.dim);
              // Reveal the receiving node's result when its last message arrives.
              if (!receivers.has(k)) updateNode(n, s, animate, direction, true);
            });
            step.edges.forEach((s, k) => {
              const e = edges[k];
              e.e.classList.toggle('off', !s.on);
              e.e.classList.toggle('dim', s.dim);
              e.e.classList.toggle('at-hi', s.heads === 'hi');
              e.e.classList.toggle('at-lo', s.heads === 'lo');
              e.e.classList.toggle('at-both', s.heads === 'both');
              e.e.classList.toggle('at-none', s.heads === 'none');
              e.label.classList.toggle('off', !s.on);
              e.label.classList.toggle('dim', s.dim);
              // An arrow carrying a message lights up as the message leaves, not before.
              setLive(e, s.live && !carriers.has(k));
              updateText(e.label, s.label, animate, direction * 4);
            });
            dots.forEach((dot, k) => dot.classList.toggle('on', k === index));
            $('prev').disabled = index === 0;
            $('next').disabled = index === S.steps.length - 1;
            if (animate && step.sends.length) {
              const tokens = activeTokens = gTokens.appendChild(el('g', {}));
              const lastArrival = new Map(step.sends.map((send, order) => [send.to, order]));
              const started = performance.now();
              let delay = M.leadIn; // Let new nodes and arrow directions settle before sending.
              step.sends.forEach((send, order) => {
                const edge = edges[send.edge], path = step.edges[send.edge].heads === 'hi' ? edge.hi : edge.lo;
                const length = path.getTotalLength();
                const duration = Math.min(M.travelMax, Math.max(M.travelMin, length * M.travelPerPx));
                const sender = nodeAt(path.getPointAtLength(send.forward ? 0 : length)), receiver = nodes[send.to];
                travel(send, tokens, path, length, started + delay, duration, () => {
                  setLive(edge, true);
                  // A faint ring as the sender emits, unless it is still lit from a message it just received.
                  if (pulses.get(sender.ring)?.playState !== 'running') pulse(sender.ring, M.emitOpacity, M.emit, M.emitScale);
                }, () => {
                  if (lastArrival.get(send.to) === order) updateNode(receiver, step.nodes[send.to], true, direction, false);
                  pulse(receiver.ring, M.arriveOpacity);
                  bump(receiver);
                });
                delay += duration + M.gap;
              });
              transitionDuration = delay - M.gap + Math.max(M.pulse, M.bump);
            }
          }

          // A tapering trail follows each message along the actual curve, in either direction. Its length
          // is the ground covered in the last moments, so it stretches mid-flight and vanishes on landing.
          // Messages in one step travel in order; the arrow lights as each leaves, the receiver responds as it lands.
          function travel(send, tokens, path, length, startAt, duration, depart, arrive) {
            const d = path.getAttribute('d'), longest = Math.min(M.trailMax, length * M.trailShare);
            const trails = M.trail.map(([width, opacity]) => tokens.appendChild(el('path', { class: 'message-trail', d,
              'stroke-width': width, 'stroke-opacity': opacity, 'stroke-dasharray': '0 ' + (length + 1), opacity: 0 })));
            const dot = tokens.appendChild(el('circle', { class: 'token', r: 0, opacity: 0 }));
            let departed = false;
            const tick = now => {
              if (tokens !== activeTokens) return;
              const t = (now - startAt) / duration;
              if (t >= 1) {
                dot.remove();
                trails.forEach(trail => trail.remove());
                arrive();
                if (!tokens.firstChild) { tokens.remove(); activeTokens = null; }
                return;
              }
              if (t >= 0) {
                if (!departed) { departed = true; depart(); }
                const u = M.travel(t), distance = u * length;
                const position = send.forward ? distance : length - distance;
                const tail = Math.min(longest, (u - M.travel(t - M.trailWindow / duration)) * length, length - distance);
                const p = path.getPointAtLength(position);
                // Grow out of the sender, then shrink into the receiver over the last stretch.
                const grow = Math.min(1, t / M.grow), absorb = Math.max(0, (t - 1 + M.absorb) / M.absorb);
                dot.setAttribute('cx', p.x);
                dot.setAttribute('cy', p.y);
                dot.setAttribute('r', absorb ? M.dot + (M.absorbR - M.dot) * absorb : M.dot * grow * (2 - grow));
                dot.setAttribute('opacity', 1 - absorb);
                trails.forEach((trail, k) => {
                  const part = tail * M.trail[k][2];
                  trail.setAttribute('stroke-dasharray', part + ' ' + (length + 1));
                  trail.setAttribute('stroke-dashoffset', -(send.forward ? position - part : position));
                  trail.setAttribute('opacity', 1 - absorb);
                });
              }
              requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          }

          function icon(playing) {
            $('play-icon').setAttribute('d', playing ? 'M4.5 3.5h2.4v9H4.5zM9.1 3.5h2.4v9H9.1z' : 'M5 3.2v9.6L12.6 8z');
            $('play').setAttribute('aria-label', playing ? 'Pause' : 'Play');
          }
          function stop() {
            if (timer === null) return;
            clearTimeout(timer);
            timer = null;
            icon(false);
          }
          function seek(i) {
            stop();
            const target = Math.max(0, Math.min(S.steps.length - 1, i));
            if (target !== index) go(target, true);
          }
          function start() {
            if (index === S.steps.length - 1) go(0, true);
            icon(true);
            const wait = () => Math.max(M.autoplay, transitionDuration + M.afterJourney);
            const advance = () => {
              if (index >= S.steps.length - 1) { stop(); return; }
              go(index + 1, true);
              timer = setTimeout(advance, wait());
            };
            timer = setTimeout(advance, wait());
          }
          $('prev').onclick = () => seek(index - 1);
          $('next').onclick = () => seek(index + 1);
          $('play').onclick = () => { timer ? stop() : start(); };
          document.addEventListener('keydown', e => {
            if (!S.stepped) return;
            if (e.key === 'ArrowRight') { seek(index + 1); e.preventDefault(); }
            if (e.key === 'ArrowLeft') { seek(index - 1); e.preventDefault(); }
            if (e.key === ' ') { timer ? stop() : start(); e.preventDefault(); }
          });

          window.flotion = { count: S.steps.length, go: seek, index: () => index };
          icon(false);
          stage.classList.add('no-anim');
          go(0, false);
          stage.getBoundingClientRect();
          stage.classList.remove('no-anim');
        })();
        """#

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
