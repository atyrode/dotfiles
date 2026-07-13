#!/usr/bin/env python3
"""Render the browsable profiles wiki (routes.html) at build time.

A *renderer* of data that lives elsewhere, so it carries ~no facts of its own:

  - omp/models.yml           the catalog: key, pool, tier, bucket, cost, context, role
  - routes.plain             the managed profile routing (ROUTES)
  - omp/PROFILES.md          the research narrative / rationale (PROFILES_MD)
  - code-profiles.tsv        the palette's group + accent per profile (CODE_PROFILES)

Emits one self-contained HTML page (inlined CSS/JS, no external deps) with a
sortable model-cost table, a sortable/filterable profile table, per-profile
routing with a lead-only ⇄ full-chains toggle, and the design rationale.
"""

import html
import os
import re
import sys


def _env_path(name, *fallback):
    p = os.environ.get(name)
    if p:
        return p
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), *fallback)


def load_yaml(path):
    import yaml

    with open(path) as f:
        return yaml.safe_load(f)


# ── inputs ────────────────────────────────────────────────────────────────────
CATALOG = load_yaml(_env_path("MODELS_YML", "..", "..", "omp", "models.yml"))["models"]

POOL_NAME = {"O": "openai-codex", "A": "anthropic"}
TIER_NAME = {0: "trivial", 1: "speed", 2: "regular", 3: "smart", 4: "elite"}

MODEL_RE = re.compile(r"(gpt|claude)[A-Za-z0-9._-]*:(?:minimal|low|medium|high|xhigh|max)")


def pool_of(model_id):
    base = model_id.split(":")[0]
    return "O" if base.startswith("gpt") else "A"


# ── palette (group + accent per profile, from code-profiles.tsv) ──────────────
PALETTE = {}  # name -> {group, color}
CODE_PROFILES = os.environ.get("CODE_PROFILES")
if CODE_PROFILES and os.path.exists(CODE_PROFILES):
    with open(CODE_PROFILES) as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) >= 7:
                PALETTE[c[0]] = {"group": c[3] or "yours", "color": c[5]}


# ── routes.plain -> per-profile routing ───────────────────────────────────────
def parse_routes(path):
    profiles = []
    cur = None
    with open(path) as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or line.startswith("OMP managed routing") or line.startswith("bundled agents"):
                continue
            if not line.startswith(" "):
                fields = line.split("  ", 1)
                cur = {
                    "name": fields[0].strip(),
                    "blurb": fields[1].strip() if len(fields) > 1 else "",
                    "meta": "",
                    "roles": [],
                }
                profiles.append(cur)
                continue
            if cur is None:
                continue
            body = line.strip()
            if "·" in body and not MODEL_RE.search(body):
                cur["meta"] = body
                continue
            agent = body.startswith("● ")
            if agent:
                body = body[2:].strip()
            parts = body.split(None, 1)
            if len(parts) < 2:
                continue
            role = parts[0]
            # finditer (not findall) — MODEL_RE has a capturing group, so we want
            # the whole match token, not the (gpt|claude) group.
            chain = [m.group(0) for m in MODEL_RE.finditer(parts[1])]
            cur["roles"].append({"role": role, "agent": agent, "chain": chain})
    return profiles


def parse_meta(meta):
    """`thinking X · fallback on · advisor Y` -> dict."""
    out = {"thinking": "", "fallback": "", "advisor": ""}
    for part in meta.split("·"):
        part = part.strip()
        for key in out:
            if part.startswith(key + " "):
                out[key] = part[len(key) + 1 :].strip()
    return out


# ── PROFILES.md -> intro + per-profile rationale ──────────────────────────────
def clean_md(s):
    """Flatten inline markdown to plain text: links, bold/italic, code, spacing."""
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)  # [text](url) -> text
    s = re.sub(r"\*\*?([^*]+)\*\*?", r"\1", s)  # **bold** / *italic* -> text
    s = s.replace("`", "")
    return " ".join(s.split())


def parse_profiles_md(path):
    intro, rationale = "", {}
    if not path or not os.path.exists(path):
        return intro, rationale
    with open(path) as f:
        text = f.read()
    # intro: first paragraph after the H1
    m = re.search(r"^# .+?\n+(.+?)\n\n", text, re.S | re.M)
    if m:
        intro = clean_md(m.group(1))
    # rationale bullets under "## Per-profile rationale", mapped by ompX mentioned
    sec = re.search(r"## Per-profile rationale\n(.+?)\n## ", text, re.S)
    if sec:
        for bullet in re.split(r"\n- ", "\n" + sec.group(1)):
            bullet = bullet.strip()
            if not bullet:
                continue
            names = set(re.findall(r"omp[a-z]", bullet))
            clean = clean_md(bullet)
            for n in names:
                rationale.setdefault(n, clean)
    return intro, rationale


# ── HTML rendering ────────────────────────────────────────────────────────────
def esc(s):
    return html.escape(str(s), quote=True)


def fmt_cost(v):
    if v is None:
        return "—"
    return ("$%g" % v)


def model_class(mid):
    return "gpt" if pool_of(mid) == "O" else "cla"


def render_chain(chain):
    """A role's model chain as spans; JS hides all but the lead in 'lead' mode."""
    out = []
    for i, tok in enumerate(chain):
        cls = model_class(tok)
        lead = " lead" if i == 0 else " fb"
        arrow = '<span class="arw">→</span>' if i else ""
        out.append(f'{arrow}<span class="m {cls}{lead}">{esc(tok)}</span>')
    return "".join(out)


def render_profile_detail(p):
    meta = parse_meta(p["meta"])
    rows = []
    for r in p["roles"]:
        marker = "●" if r["agent"] else ""
        rows.append(
            f'<tr><td class="role">{marker} {esc(r["role"])}</td>'
            f'<td class="chain">{render_chain(r["chain"])}</td></tr>'
        )
    return (
        f'<table class="routing"><tbody>{"".join(rows)}</tbody></table>'
    )


def main():
    routes = parse_routes(_env_path("ROUTES", "..", "..", "does-not-exist"))
    # routes.plain ends with an explanatory prose footer whose non-indented lines
    # look like block headers; a real profile has routing rows, prose has none.
    routes = [p for p in routes if p["roles"]]
    intro, rationale = parse_profiles_md(os.environ.get("PROFILES_MD"))

    # ── model catalog rows (models.yml order = tier-ish curation) ──
    cat_rows = []
    for key, v in CATALOG.items():
        ctx = v.get("context")
        ctx_disp = f"{ctx // 1000}K" if ctx else "—"
        think_disp = v.get("thinking") or "—"
        ci, co = v.get("cost_in"), v.get("cost_out")
        sp, tt = v.get("speed"), v.get("ttft")
        sp_disp = f"{sp:g} t/s" if sp else "—"
        tt_disp = f"{tt:g}s" if tt is not None else "—"
        cat_rows.append(
            f'<tr class="{model_class(v["id"])}">'
            f'<td class="key">{esc(key)}</td>'
            f'<td class="mono">{esc(v["id"])}</td>'
            f'<td>{esc(POOL_NAME[v["pool"]])}</td>'
            f'<td data-sort="{v["tier"]}">{esc(TIER_NAME.get(v["tier"], v["tier"]))}</td>'
            f'<td data-sort="{ci if ci is not None else -1}" class="num">{fmt_cost(ci)}</td>'
            f'<td data-sort="{co if co is not None else -1}" class="num">{fmt_cost(co)}</td>'
            f'<td data-sort="{ctx or 0}" class="num">{ctx_disp}</td>'
            f'<td data-sort="{sp or 0}" class="num">{sp_disp}</td>'
            f'<td data-sort="{tt if tt is not None else 999}" class="num">{tt_disp}</td>'
            f'<td>{esc(think_disp)}</td>'
            f'<td>{esc(v["bucket"])}</td>'
            f'<td class="role-note">{esc(v.get("role", ""))}</td>'
            f"</tr>"
        )

    # ── profile rows + detail panels ──
    prof_rows, panels = [], []
    for p in routes:
        name = p["name"]
        pal = PALETTE.get(name, {"group": "yours", "color": "#78c8aa"})
        meta = parse_meta(p["meta"])
        lead = p["roles"][0]["chain"][0] if p["roles"] and p["roles"][0]["chain"] else "—"
        why = rationale.get(name, "")
        prof_rows.append(
            f'<tr class="prow" data-group="{esc(pal["group"])}" data-name="{esc(name)}" '
            f'style="--accent:{esc(pal["color"])}">'
            f'<td class="pname"><button class="disc" aria-expanded="false">▸</button>'
            f'<span class="dot"></span><b>{esc(name)}</b></td>'
            f'<td>{esc(pal["group"])}</td>'
            f'<td>{esc(meta["thinking"])}</td>'
            f'<td>{esc(meta["advisor"])}</td>'
            f'<td>{esc(meta["fallback"])}</td>'
            f'<td class="mono lead-cell">{render_chain([lead])}</td>'
            f'<td class="blurb">{esc(p["blurb"])}</td>'
            f"</tr>"
            f'<tr class="detail" data-for="{esc(name)}" hidden><td colspan="7">'
            f'<div class="detail-in">{render_profile_detail(p)}'
            + (f'<p class="why"><b>Why this routing</b> — {esc(why)}</p>' if why else "")
            + "</div></td></tr>"
        )

    groups = []
    seen = set()
    for p in routes:
        g = PALETTE.get(p["name"], {}).get("group", "yours")
        if g not in seen:
            seen.add(g)
            groups.append(g)

    filter_btns = '<button class="fbtn active" data-f="all">all</button>' + "".join(
        f'<button class="fbtn" data-f="{esc(g)}">{esc(g)}</button>' for g in groups
    )

    page = (
        PAGE.replace("__INTRO__", esc(intro))
        .replace("__CAT_ROWS__", "".join(cat_rows))
        .replace("__PROF_ROWS__", "".join(prof_rows))
        .replace("__FILTER_BTNS__", filter_btns)
    )
    print(page)


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OMP profiles — routing wiki</title>
<style>
:root {
  --bg:#0f131a; --panel:#161b24; --line:#2a3240; --fg:#dce3ee; --dim:#8792a5;
  --gpt:#7fb0ff; --cla:#ffb277; --accent:#8aa0c8;
}
@media (prefers-color-scheme: light) {
  :root { --bg:#f6f8fb; --panel:#fff; --line:#dde3ec; --fg:#1b2230; --dim:#5c6675;
           --gpt:#2f6fd0; --cla:#c96a1e; }
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
  font:15px/1.55 ui-sans-serif,-apple-system,Segoe UI,Roboto,Inter,sans-serif; }
.wrap { max-width:1160px; margin:0 auto; padding:28px 20px 80px; }
h1 { font-size:26px; margin:0 0 6px; }
h2 { font-size:19px; margin:38px 0 12px; padding-bottom:6px; border-bottom:1px solid var(--line); }
.intro { color:var(--dim); max-width:74ch; }
.mono { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12.5px; }
.toolbar { display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin:14px 0; }
input.search { background:var(--panel); border:1px solid var(--line); color:var(--fg);
  border-radius:8px; padding:7px 11px; font-size:14px; min-width:200px; }
.fbtn, .toggle { background:var(--panel); border:1px solid var(--line); color:var(--dim);
  border-radius:999px; padding:5px 12px; font-size:13px; cursor:pointer; }
.fbtn.active { color:var(--fg); border-color:var(--accent); box-shadow:0 0 0 1px var(--accent) inset; }
.toggle.on { color:var(--fg); border-color:var(--accent); }
table { border-collapse:collapse; width:100%; background:var(--panel);
  border:1px solid var(--line); border-radius:12px; overflow:hidden; }
.scroll { overflow-x:auto; }
th, td { text-align:left; padding:9px 12px; border-bottom:1px solid var(--line); vertical-align:top; }
th { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--dim);
  cursor:pointer; user-select:none; white-space:nowrap; position:sticky; top:0; background:var(--panel); }
th.sorted::after { content:" ▾"; } th.sorted.asc::after { content:" ▴"; }
tr:last-child td { border-bottom:none; }
td.num { text-align:right; font-variant-numeric:tabular-nums; }
td.key { font-weight:600; }
.role-note { color:var(--dim); font-size:13px; max-width:34ch; }
.gpt td.key, .m.gpt { color:var(--gpt); }
.cla td.key, .m.cla { color:var(--cla); }
.m { font-family:ui-monospace,monospace; font-size:12px; }
.arw { color:var(--dim); margin:0 5px; }
.dot { display:inline-block; width:9px; height:9px; border-radius:3px; background:var(--accent);
  margin-right:8px; vertical-align:middle; }
.prow { --accent:#8aa0c8; }
.prow td .dot { background:var(--accent); }
.disc { background:none; border:none; color:var(--dim); cursor:pointer; font-size:12px;
  padding:0 8px 0 0; }
.prow.open .disc { transform:rotate(90deg); display:inline-block; }
.pname { white-space:nowrap; }
.blurb { color:var(--dim); }
.detail-in { padding:6px 4px 12px 26px; }
table.routing { border:none; background:transparent; width:auto; }
table.routing td { border:none; padding:3px 14px 3px 0; }
td.role { color:var(--dim); font-size:13px; white-space:nowrap; }
body.lead .m.fb, body.lead .routing .arw { display:none; }
.why { color:var(--dim); font-size:13.5px; max-width:80ch; margin:10px 0 0; }
footer { margin-top:40px; color:var(--dim); font-size:12.5px; }
</style>
</head>
<body class="lead">
<div class="wrap">
  <h1>OMP profiles — routing wiki</h1>
  <p class="intro">__INTRO__</p>

  <h2>Model catalog</h2>
  <p class="intro">Cost ($ per 1M tokens in / out) and context come from
    <span class="mono">omp models</span>; speed (output tok/s) and ttft (time-to-first-token)
    from <span class="mono">omp bench</span>; the short key, tier, bucket, and role from
    <span class="mono">models.yml</span>. Click a header to sort.</p>
  <div class="scroll"><table id="models">
    <thead><tr>
      <th>key</th><th>model</th><th>pool</th><th>tier</th>
      <th class="num">$ in</th><th class="num">$ out</th><th class="num">context</th>
      <th class="num">speed</th><th class="num">ttft</th>
      <th>thinking</th><th>bucket</th><th>role</th>
    </tr></thead>
    <tbody>__CAT_ROWS__</tbody>
  </table></div>

  <h2>Profiles</h2>
  <div class="toolbar">
    <input class="search" id="search" placeholder="filter profiles…" autocomplete="off">
    __FILTER_BTNS__
    <span style="flex:1"></span>
    <button class="toggle" id="depth">show full fallback chains</button>
  </div>
  <div class="scroll"><table id="profiles">
    <thead><tr>
      <th>profile</th><th>group</th><th>thinking</th><th>advisor</th><th>fallback</th>
      <th>lead</th><th>blurb</th>
    </tr></thead>
    <tbody>__PROF_ROWS__</tbody>
  </table></div>

  <footer>Generated at build time from models.yml + <span class="mono">omp models</span> +
    routes.plain + PROFILES.md. Nothing here is hand-maintained — edit the source, not the page.</footer>
</div>
<script>
// sortable tables
document.querySelectorAll('table thead th').forEach((th, i) => {
  th.addEventListener('click', () => {
    const table = th.closest('table'), tb = table.tBodies[0];
    const rows = [...tb.querySelectorAll('tr:not(.detail)')];
    const asc = !(th.classList.contains('sorted') && !th.classList.contains('asc'));
    table.querySelectorAll('th').forEach(h => h.classList.remove('sorted','asc'));
    th.classList.add('sorted'); if (asc) th.classList.add('asc');
    const val = tr => {
      const c = tr.children[i]; const d = c.getAttribute('data-sort');
      return d !== null ? parseFloat(d) : c.textContent.trim().toLowerCase();
    };
    rows.sort((a,b) => { const x=val(a),y=val(b);
      const r = (typeof x==='number'&&typeof y==='number') ? x-y : (''+x).localeCompare(''+y);
      return asc ? r : -r; });
    rows.forEach(r => { tb.appendChild(r);
      const det = tb.querySelector('tr.detail[data-for="'+r.dataset.name+'"]');
      if (det) tb.appendChild(det); });
  });
});
// expand/collapse profile detail
document.querySelectorAll('#profiles .prow').forEach(row => {
  row.querySelector('.disc').addEventListener('click', e => {
    e.stopPropagation();
    const det = document.querySelector('tr.detail[data-for="'+row.dataset.name+'"]');
    const open = row.classList.toggle('open');
    row.querySelector('.disc').setAttribute('aria-expanded', open);
    if (det) det.hidden = !open;
  });
});
// filter buttons
document.querySelectorAll('.fbtn').forEach(b => b.addEventListener('click', () => {
  document.querySelectorAll('.fbtn').forEach(x => x.classList.remove('active'));
  b.classList.add('active'); applyFilter();
}));
document.getElementById('search').addEventListener('input', applyFilter);
function applyFilter() {
  const q = document.getElementById('search').value.toLowerCase();
  const g = document.querySelector('.fbtn.active').dataset.f;
  document.querySelectorAll('#profiles .prow').forEach(row => {
    const okG = g === 'all' || row.dataset.group === g;
    const okQ = !q || row.textContent.toLowerCase().includes(q);
    const show = okG && okQ; row.style.display = show ? '' : 'none';
    const det = document.querySelector('tr.detail[data-for="'+row.dataset.name+'"]');
    if (det && !show) { det.hidden = true; row.classList.remove('open'); }
  });
}
// lead-only ⇄ full chains
document.getElementById('depth').addEventListener('click', function() {
  const full = document.body.classList.toggle('lead') === false;
  this.classList.toggle('on', full);
  this.textContent = full ? 'show lead only' : 'show full fallback chains';
});
</script>
</body>
</html>"""


if __name__ == "__main__":
    sys.exit(main())
