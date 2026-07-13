#!/usr/bin/env python3
"""Generate the full facet grid of profiles from first principles.

Runs at package build time. For every valid (lane, model-tier, thinking, spark,
fable) combination it emits a block in the same plain format render-omp-routes.sh
produces, so the `code` picker's colorize_routes can render it unchanged:

    <combo-id>  <lane> · <model-tier> · <thinking>[ · spark][ · fable]
      thinking <t> · fallback on · advisor <on|off>
      ● default    <model:level>  → <fallback> → ...
      ...

The combo-id is `<lane>_<mtier>_<thinking>_<sp|nosp>_<fa|nofa>` — the runtime
facet selector rebuilds the same id from the current facet state to look up the
block. The model catalog is loaded from omp/models.yml (issue #79).
"""

import os

import yaml

# ── model catalog (from omp/models.yml — the single source of truth) ──────────
# short key -> full model id, provider pool (O/A), quota bucket, and tier
# (0 trivial .. 3 smart, 4 elite). Fallback ladders are per pool by tier.
_MODELS_YML = os.environ.get(
    "MODELS_YML",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "omp", "models.yml"),
)
with open(_MODELS_YML) as _f:
    CATALOG = yaml.safe_load(_f)["models"]

ID = {k: v["id"] for k, v in CATALOG.items()}
PROV = {k: v["pool"] for k, v in CATALOG.items()}
TIER = {k: v["tier"] for k, v in CATALOG.items()}
# LADDER[pool][tier] is the ladder rung; tiers 1..3 only (0/4 are special leads).
LADDER = {"O": [None, None, None, None], "A": [None, None, None, None]}
for _k, _v in CATALOG.items():
    if 1 <= _v["tier"] <= 3:
        LADDER[_v["pool"]][_v["tier"]] = _k
CHEAP = {p: LADDER[p][1] for p in ("O", "A")}

# Per-model thinking range, parsed from the catalog's `thinking: lo→hi` field
# (mirrors omp's vocabulary: minimal < low < medium < high < xhigh < max). Each
# model supports a contiguous slice of that scale, so clamping any level into
# [lo, hi] resolves the extremes per model for free: 'minimal' → the model's floor
# (minimal for haiku, low for the rest) and 'max' → its ceiling (max for most,
# xhigh for spark/haiku). It also keeps every emitted level one the model actually
# offers — e.g. luna has no 'minimal', so luna:minimal clamps to luna:low.
SCALE = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']
SIDX = {lv: i for i, lv in enumerate(SCALE)}
TH_RANGE = {}
for _k, _v in CATALOG.items():
    _lo, _hi = (s.strip() for s in _v["thinking"].split('→'))
    TH_RANGE[_k] = (SIDX[_lo], SIDX[_hi])


def clamp_th(model, level):
    lo, hi = TH_RANGE[model]
    return SCALE[max(lo, min(hi, SIDX[level]))]


def other(p):
    return 'A' if p == 'O' else 'O'


def sib_down(m):
    if m == 'fable':
        return 'opus'  # Fable falls to main-plan Opus
    p = PROV[m]
    t = TIER.get(m, 0)
    return LADDER[p][t - 1] if t >= 2 else None


def cross(m):
    p = other(PROV[m])
    t = min(3, TIER.get(m, 3))
    return LADDER[p][t]


def dedup(seq, lead):
    out = []
    for x in seq:
        if x and x != lead and x not in out:
            out.append(x)
    return out


def build_chain(lead, is_pure):
    sib = sib_down(lead)
    if is_pure:
        raw = [sib, sib_down(sib) if sib else None]
    else:
        c = cross(lead)
        raw = [sib, c, sib_down(c)]
    return dedup(raw, lead)


ROLE_ORDER = ['default', 'task', 'plan', 'slow', 'designer', 'reviewer',
              'librarian', 'sonic', 'advisor', 'smol', 'tiny', 'commit']
AGENT_ROLES = {'designer', 'librarian', 'reviewer', 'sonic', 'task'}  # ● marker
DELIB = {'plan', 'slow', 'designer', 'reviewer'}
# Anti-tunnel-vision (issue: provider diversity). On a *-led lane the default and
# the bulk of the profile stay on the preferred provider (strong emphasis), but a
# couple of critique roles cross to the opposite provider so the work always gets
# a genuinely independent second eye. The advisor always crosses too (handled in
# its own branch); the reviewer is the other cross role — it audits the output, so
# a different provider there is where diverse judgement pays off most.
CROSS_LED = {'reviewer'}

# Utility roles all respond to the sliders, but each to a degree that fits its
# job — model tier is capped so none can ever become expensive. Provider comes
# from rprov(); tier indexes LADDER (1 cheapest sibling .. 2 mid). Purposes:
#   commit — commit messages (text-trivial):        always cheapest
#   tiny   — labels (text-trivial):                  cheapest, a touch on smart
#   smol   — fast lookup/naming + repo exploration:  rises at normal
#   sonic  — the fast interactive agent:             rises at normal, keeps a net
UTIL = {'sonic', 'smol', 'tiny', 'commit'}
# gpt-5.3-codex-spark is very fast but low-capability, so it only belongs where
# dumbness is harmless: commit/tiny (formulaic text) whenever spark is on, and
# sonic only on a 'fast' model-tier (an explicit speed-over-smarts choice). smol
# backs repo exploration, so it never uses spark.
UTIL_MODEL = {
    'commit': {'fast': 1, 'normal': 1, 'smart': 1},
    'tiny':   {'fast': 1, 'normal': 1, 'smart': 2},
    'smol':   {'fast': 1, 'normal': 2, 'smart': 2},
    'sonic':  {'fast': 1, 'normal': 2, 'smart': 2},
}
UTIL_THINK = {  # kept low — these roles must stay fast/cheap even on deep profiles
    'commit': {'low': 'minimal', 'medium': 'minimal', 'high': 'minimal', 'xhigh': 'low'},
    'tiny':   {'low': 'minimal', 'medium': 'low', 'high': 'low', 'xhigh': 'low'},
    'smol':   {'low': 'low', 'medium': 'low', 'high': 'medium', 'xhigh': 'medium'},
    'sonic':  {'low': 'low', 'medium': 'medium', 'high': 'medium', 'xhigh': 'medium'},
}
# Advisor power/cost dial, emitted as a table the code picker reads (so the
# catalog stays the single source of truth). Keyed by context — 'gpt' on a pure
# GPT pool, else 'claude' for the most independent cross-provider second opinion.
ADVISOR = {
    'claude': {
        'glance': [('haiku', 'low')],
        'review': [('sonnet', 'medium'), ('haiku', 'low')],
        'audit': [('opus', 'high'), ('sonnet', 'high'), ('haiku', 'low')],
    },
    'gpt': {
        'glance': [('luna', 'low')],
        'review': [('terra', 'medium'), ('luna', 'low')],
        'audit': [('sol', 'high'), ('terra', 'high'), ('luna', 'low')],
    },
}
TMAP = {'fast': 1, 'normal': 2, 'smart': 3}
BUMP = {'minimal': 'low', 'low': 'medium', 'medium': 'high', 'high': 'xhigh', 'xhigh': 'xhigh'}
LANES = ['gpt-only', 'gpt-led', 'mixed', 'claude-led', 'claude-only']
MTIERS = ['fast', 'normal', 'smart']
# The middle levels scale per role (deliberation bumps up, utilities stay modest);
# the two extremes are uniform overrides — 'minimal' floors every role, 'max' tops
# every role — each clamped to what its model actually supports (see clamp_th).
THINKING = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']
EXTREMES = {'minimal', 'max'}


def primary(lane):
    return 'O' if lane in ('gpt-only', 'gpt-led', 'mixed') else 'A'


def pure(lane):
    return lane in ('gpt-only', 'claude-only')


def gen(lane, mtier, thinking, spark, fable):
    """Return {role: (lead_key, level, [chain (key, level)...])}."""
    P = primary(lane)
    base = TMAP[mtier]
    isp = pure(lane)
    extreme = thinking in EXTREMES  # 'minimal'/'max' override every role uniformly

    def rprov(r):
        if isp:
            return P                       # pure lane: never cross
        if lane == 'mixed':
            return 'A' if r in DELIB else 'O'
        # *-led: strong primary everywhere, except the cross-provider critique roles
        return other(P) if r in CROSS_LED else P

    out = {}
    for r in ROLE_ORDER:
        if r in UTIL:
            rp = rprov(r)
            t = UTIL_MODEL[r][mtier]
            th = thinking if extreme else UTIL_THINK[r][thinking]
            spark_here = spark and (r in ('tiny', 'commit') or (r == 'sonic' and mtier == 'fast'))
            if spark_here:
                lead = 'spark'                 # fast codex tier; keep it snappy
                if not extreme:
                    th = 'low'
                fb = [LADDER[rp][t]]           # fall to the role's normal model
            else:
                lead = LADDER[rp][t]
                sd = sib_down(lead) if r == 'sonic' else None  # only sonic keeps a net
                fb = [sd] if sd else []
            out[r] = (lead, th, [(m, th) for m in dedup(fb, lead)])
            continue
        if r == 'advisor':
            if mtier == 'fast':
                out[r] = (None, None, [])  # advisor off
                continue
            # The advisor is the independent second opinion, so it leads on the
            # opposite provider whenever the lane allows crossing (everything but
            # the pure lanes) — the minimum diversity guarantee for any profile.
            AP = P if isp else other(P)
            amod = (LADDER[AP][2] if AP == 'A' else 'terra') if mtier == 'smart' else CHEAP[AP]
            lvl = thinking if extreme else ('high' if mtier == 'smart' else 'low')
            fbl = thinking if extreme else 'low'
            out[r] = (amod, lvl, [(m, fbl) for m in build_chain(amod, isp)])
            continue
        rp = rprov(r)
        t = min(3, base + 1) if r in DELIB else base
        th = thinking if extreme else (BUMP[thinking] if r in DELIB else thinking)
        lead = 'fable' if (fable and r in DELIB and rp == 'A' and mtier in ('smart', 'normal')) else LADDER[rp][t]
        out[r] = (lead, th, [(m, th) for m in build_chain(lead, isp)])
    return out


def combo_id(lane, mtier, thinking, spark, fable):
    return f"{lane}_{mtier}_{thinking}_{'sp' if spark else 'nosp'}_{'fa' if fable else 'nofa'}"


def render(lane, mtier, thinking, spark, fable):
    roles = gen(lane, mtier, thinking, spark, fable)
    cid = combo_id(lane, mtier, thinking, spark, fable)
    desc_bits = [lane, mtier, thinking]
    if spark:
        desc_bits.append('spark')
    if fable:
        desc_bits.append('fable')
    lines = [f"{cid}  {' · '.join(desc_bits)}"]
    adv_on = roles['advisor'][0] is not None
    lines.append(f"  thinking {thinking} · fallback on · advisor {'on' if adv_on else 'off'}")
    for r in ROLE_ORDER:
        lead, lvl, chain = roles[r]
        if lead is None:  # advisor off — no row (matches render-omp-routes skip)
            continue
        marker = '●' if r in AGENT_ROLES else ' '
        model = f"{ID[lead]}:{clamp_th(lead, lvl)}"
        row = f"  {marker} {r:<10} {model:<24}"
        for (m, ml) in chain:
            row += f" → {ID[m]}:{clamp_th(m, ml)}"
        lines.append(row.rstrip())
    lines.append("")
    return "\n".join(lines)


def render_advisors():
    """Emit the advisor dial as a pseudo-block the picker parses (level context
    → chain), so the advisor model names live here, not duplicated in the TUI."""
    lines = ["__advisors__  advisor dial (level context → chain)"]
    for ctx in ('gpt', 'claude'):
        for level in ('glance', 'review', 'audit'):
            chain = ' → '.join(f"{ID[k]}:{clamp_th(k, lv)}" for k, lv in ADVISOR[ctx][level])
            lines.append(f"  {level} {ctx} {chain}")
    lines.append("")
    return "\n".join(lines)


def valid(lane, mtier, thinking, spark, fable):
    if lane == 'gpt-only' and fable:
        return False       # no Fable on pure GPT
    if lane == 'claude-only' and spark:
        return False       # no Spark on pure Claude
    return True


def main():
    print("OMP generated routing — first-principles facet grid")
    print("bundled agents: designer librarian reviewer sonic task — ● marks an agent-backed role\n")
    print(render_advisors())
    for lane in LANES:
        for mtier in MTIERS:
            for thinking in THINKING:
                for spark in (True, False):
                    for fable in (True, False):
                        if valid(lane, mtier, thinking, spark, fable):
                            print(render(lane, mtier, thinking, spark, fable))


if __name__ == '__main__':
    main()
