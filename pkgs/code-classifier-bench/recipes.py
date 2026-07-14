"""System-prompt / recipe variations for the prompt->profile classifier.

This module is the single place that knows (a) how the operator's real omp
model+thinking settings map onto the classifier's facet vocabulary, and (b) the
set of system-prompt VARIATIONS the benchmark sweeps. It has no third-party
dependencies so the harness runs with a bare python3 and a live ollama daemon.

The `baseline` variation mirrors the shipped classifier in
`pkgs/code-tui/suggest.go` as of PR #139 (the local ollama/qwen2.5:3b evaluator).
Keep it in sync by hand if that recipe changes — the whole point of this harness
is to compare *alternatives* against that baseline, so a faithful baseline is the
reference every other variation is measured against.
"""

# ── operator settings -> classifier facet vocabulary ────────────────────────
#
# The classifier only ever emits model in {fast, normal, smart} and thinking in
# {minimal, medium, high, xhigh} (plus max), per the difficulty rubric. The
# operator's sessions record the *actual* omp model id and thinking level they
# ran with, so to score alignment we fold each real model onto the tier bucket
# the classifier could have picked.
#
# tier -> facet mirrors omp/models.yml (tier: 0 fast·1 speed·2 regular·3 smart·4
# elite). 0 and 1 both collapse to the classifier's "fast"; 2 -> "normal"; 3 and
# 4 -> "smart" (tier 4 = fable, the elite lead, which the classifier reaches via
# the critical tier + the deriveToggles fable flag, not a distinct model value).
_TIER_OF_MODEL = {
    # openai-codex pool
    "gpt-5.6-luna": 1,
    "gpt-5.6-terra": 2,
    "gpt-5.6-sol": 3,
    "gpt-5.3-codex-spark": 0,
    # anthropic pool
    "claude-haiku-4-5": 1,
    "claude-sonnet-5": 2,
    "claude-opus-4-8": 3,
    "claude-fable-5": 4,
    # older flagship, retired from the catalog — was the pre-5.6 smart default.
    "gpt-5.5": 3,
}
_FACET_OF_TIER = {0: "fast", 1: "fast", 2: "normal", 3: "smart", 4: "smart"}

# omp's configured default when a session recorded no explicit model/thinking
# (omp/defaults.yml: modelRoles.default = openai-codex/gpt-5.6-sol:medium).
DEFAULT_MODEL = "gpt-5.6-sol"
DEFAULT_THINKING = "medium"


def strip_provider(model):
    """openai-codex/gpt-5.6-sol -> gpt-5.6-sol; None -> the omp default."""
    if not model:
        return DEFAULT_MODEL
    return model.split("/")[-1]


def model_to_facet(model):
    """Fold a raw omp model id onto the classifier's model facet.

    Returns (facet, elite) where facet is fast/normal/smart and elite is True for
    the scarce fable lead (tier 4) — the classifier expresses that as
    critical-tier settings, so it is tracked separately from the plain facet.
    """
    mid = strip_provider(model)
    tier = _TIER_OF_MODEL.get(mid)
    if tier is None:
        # Unknown model: assume a flagship (safest for divergence — surfaces as
        # "operator wanted smart" so a fast pick still reads as a miss).
        tier = 3
    return _FACET_OF_TIER[tier], tier == 4


# The classifier never emits low; the operator does. low sits between minimal and
# medium — fold it to the nearer emitted level (minimal) for exact-match scoring,
# but the report also shows the raw level so this fold is never silent.
_THINKING_CANON = {
    None: DEFAULT_THINKING,
    "": DEFAULT_THINKING,
    "low": "minimal",
}


def thinking_to_facet(level):
    return _THINKING_CANON.get(level, level)


# Ordinal ladder for "off-by-one vs far-off" divergence classification.
THINKING_ORDER = ["minimal", "medium", "high", "xhigh", "max"]
MODEL_ORDER = ["fast", "normal", "smart"]

# ── the classifier recipe (baseline, from PR #139 suggest.go) ────────────────

MAX_CLASSIFY_CHARS = 600  # suggest.go: maxClassifyChars


def truncate_for_classify(task):
    if len(task) <= MAX_CLASSIFY_CHARS:
        return task
    return task[:MAX_CLASSIFY_CHARS] + " …"


# Exact system prompt from suggest.go (evalSystemPrompt).
_BASELINE_SYSTEM = (
    "You size a coding task by rating its difficulty, then give the matching "
    "agent settings. You never do, answer, or research the task itself. Reply in "
    "exactly two lines, nothing else."
)

# The difficulty rubric body from suggest.go's classifyMessage, without the final
# task block (each variation appends the task the same way via _with_task).
_BASELINE_RUBRIC = (
    "Rate the task's difficulty, then the matching settings.\n"
    "Difficulty → settings:\n"
    "  trivial  = typo, rename, one-liner, a what-is/lookup       -> model=fast,   thinking=minimal, advisor=off\n"
    "  moderate = a small feature, an endpoint, a simple script   -> model=normal, thinking=medium,  advisor=glance\n"
    "  hard     = tricky logic, a refactor, perf work, ambiguity  -> model=smart,  thinking=high,    advisor=review\n"
    "  critical = security, must be exact / zero-failure / thorough, architecture, migration -> model=smart, thinking=xhigh, advisor=audit\n"
    "Escalate when the task demands precision, exhaustiveness, or safety.\n"
    "Reply in exactly two lines, like this example:\n"
    "hard — tricky refactor across modules\n"
    '{"model":"smart","thinking":"high","advisor":"review"}\n'
)

# A per-parameter glossary — the operator's suggested experiment: tell the model
# what each knob actually ADJUSTS, not just which difficulty maps to which value.
# Text drawn from the facetGuide hints in the pre-#139 suggest.go.
_PARAM_GLOSSARY = (
    "What each setting adjusts:\n"
    "  model    — speed/quality tier: fast is cheap and quick, normal is the "
    "balanced workhorse, smart is the strongest and slowest.\n"
    "  thinking — how much the agent reasons before acting, minimal→max; more is "
    "slower but catches more.\n"
    "  advisor  — a peer reviewer on each turn: off (none), glance (a quick "
    "look), review (a real review), audit (a deep, expensive check).\n"
)


def _with_task(body, task):
    return body + 'Now the task:\n"""\n' + truncate_for_classify(task) + '\n"""'


# Each variation is (system_prompt, wrap(task) -> user_message).
VARIATIONS = {
    # Faithful reproduction of the shipped classifier (PR #139).
    "baseline": (
        _BASELINE_SYSTEM,
        lambda task: _with_task(_BASELINE_RUBRIC, task),
    ),
    # Operator's experiment, placement A: the parameter glossary in the SYSTEM
    # prompt (where PR #139's role text lives).
    "glossary_system": (
        _BASELINE_SYSTEM + "\n\n" + _PARAM_GLOSSARY,
        lambda task: _with_task(_BASELINE_RUBRIC, task),
    ),
    # Operator's experiment, placement B: the glossary INLINE in the user turn,
    # right before the rubric — small models weight the user turn more heavily,
    # so where the explanation lives may matter as much as whether it exists.
    "glossary_inline": (
        _BASELINE_SYSTEM,
        lambda task: _with_task(_PARAM_GLOSSARY + "\n" + _BASELINE_RUBRIC, task),
    ),
    # Control: the mapping table with NO worked example and NO glossary, to
    # isolate how much the example line in the baseline is doing.
    "no_example": (
        _BASELINE_SYSTEM,
        lambda task: _with_task(
            "Rate the task's difficulty, then output the matching settings as JSON.\n"
            "  trivial  -> model=fast,   thinking=minimal, advisor=off\n"
            "  moderate -> model=normal, thinking=medium,  advisor=glance\n"
            "  hard     -> model=smart,  thinking=high,    advisor=review\n"
            "  critical -> model=smart,  thinking=xhigh,   advisor=audit\n",
            task,
        ),
    ),
}
