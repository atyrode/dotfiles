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
block. The catalog below is the future models.yml (issue #79).
"""

# ── model catalog ────────────────────────────────────────────────────────────
# short key -> full model id (what routing/colorize expects), provider, bucket,
# tier (0 trivial .. 3 smart, 4 elite). Fallback ladders are per provider by tier.
ID = {
    'luna': 'gpt-5.6-luna', 'terra': 'gpt-5.6-terra', 'sol': 'gpt-5.6-sol',
    'nano': 'gpt-5.4-nano', 'spark': 'gpt-5.3-codex-spark',
    'haiku': 'claude-haiku-4-5', 'sonnet': 'claude-sonnet-5',
    'opus': 'claude-opus-4-8', 'fable': 'claude-fable-5',
}
LADDER = {'O': [None, 'luna', 'terra', 'sol'], 'A': [None, 'haiku', 'sonnet', 'opus']}
TIER = {'luna': 1, 'terra': 2, 'sol': 3, 'haiku': 1, 'sonnet': 2, 'opus': 3, 'fable': 4}
PROV = {k: ('O' if ID[k].startswith('gpt') else 'A') for k in ID}
CHEAP = {'O': 'luna', 'A': 'haiku'}


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
TMAP = {'fast': 1, 'normal': 2, 'smart': 3}
BUMP = {'minimal': 'low', 'low': 'medium', 'medium': 'high', 'high': 'xhigh', 'xhigh': 'xhigh'}
LANES = ['gpt-only', 'gpt-led', 'mixed', 'claude-led', 'claude-only']
MTIERS = ['fast', 'normal', 'smart']
THINKING = ['low', 'medium', 'high', 'xhigh']


def primary(lane):
    return 'O' if lane in ('gpt-only', 'gpt-led', 'mixed') else 'A'


def pure(lane):
    return lane in ('gpt-only', 'claude-only')


def gen(lane, mtier, thinking, spark, fable):
    """Return {role: (lead_key, level, [chain (key, level)...])}."""
    P = primary(lane)
    S = other(P)
    base = TMAP[mtier]
    isp = pure(lane)

    def rprov(r):
        if isp:
            return P
        if lane == 'mixed':
            return 'A' if r in DELIB else 'O'
        return P

    out = {}
    for r in ROLE_ORDER:
        if r in UTIL:
            rp = rprov(r)
            t = UTIL_MODEL[r][mtier]
            th = UTIL_THINK[r][thinking]
            spark_here = spark and (r in ('tiny', 'commit') or (r == 'sonic' and mtier == 'fast'))
            if spark_here:
                lead, th = 'spark', 'low'      # fast codex tier; keep it snappy
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
            amod = (LADDER[P][2] if P == 'A' else 'terra') if mtier == 'smart' else CHEAP[P]
            lvl = 'high' if mtier == 'smart' else 'low'
            out[r] = (amod, lvl, [(m, 'low') for m in build_chain(amod, isp)])
            continue
        rp = rprov(r)
        t = min(3, base + 1) if r in DELIB else base
        th = BUMP[thinking] if r in DELIB else thinking
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
        model = f"{ID[lead]}:{lvl}"
        row = f"  {marker} {r:<10} {model:<24}"
        for (m, ml) in chain:
            row += f" → {ID[m]}:{ml}"
        lines.append(row.rstrip())
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
    for lane in LANES:
        for mtier in MTIERS:
            for thinking in THINKING:
                for spark in (True, False):
                    for fable in (True, False):
                        if valid(lane, mtier, thinking, spark, fable):
                            print(render(lane, mtier, thinking, spark, fable))


if __name__ == '__main__':
    main()
