"""The numbered promise must match every executed or abandoned step."""

import re
from pathlib import Path
import sys

for filename in sys.argv[1:]:
    text = re.sub(r"\x1b\[[0-9;]*m", "", Path(filename).read_text())
    planned = [(int(n), label.rstrip(".")) for n, label in re.findall(r"^  (\d+)\. (.+)$", text, re.M)]
    executed = [(int(n), int(total), label.rstrip(".")) for n, total, label in re.findall(r"^(\d+)/(\d+) (.+)$", text, re.M)]
    assert planned, f"{filename}: no plan was exercised"
    assert executed, f"{filename}: no execution or abandonment was exercised"
    assert [n for n, _ in planned] == list(range(1, len(planned) + 1)), filename
    assert [(n, label) for n, _, label in executed] == planned, f"{filename}: execution differs from promised plan"
    assert all(total == len(planned) for _, total, _ in executed), f"{filename}: step denominators disagree with plan"
