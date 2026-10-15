#!/usr/bin/env python3
"""Check a scripts/build-cost.sh JSON line against build-budget.json.

Used by the `build-cost` job in .github/workflows/workspace-rust.yml (plan
verb-pipeline-and-transport.md § Build cost, B5). Takes the JSON record on
stdin, prints DET_FAIL=... and MEASURED_FAIL=... lines (empty on pass) so the
workflow step can `source` the output and decide whether to re-run or fail.
"""
import json
import shlex
import sys

DETERMINISTIC = ("macro_lines_per_verb", "total_lines_per_verb")
MEASURED = ("cold_ms_per_verb", "incr_service_ms_per_verb", "incr_core_ms_per_verb")


def main() -> None:
    record = json.loads(sys.stdin.read())
    budgets = json.load(open("build-budget.json"))["budgets"]

    det_fail = [
        f"{k}={record[k]}>{budgets[k]}" for k in DETERMINISTIC if record[k] > budgets[k]
    ]
    measured_fail = [
        f"{k}={record[k]}>{budgets[k]}" for k in MEASURED if record[k] > budgets[k]
    ]

    # Quoted: the workflow `source`s this, and an unquoted `a=29>12|b=60>48`
    # is a redirect and a pipe — the variable was never set, `set -u` killed
    # the step, and the one re-run the measured half is promised never ran.
    print(f"DET_FAIL={shlex.quote('|'.join(det_fail))}")
    print(f"MEASURED_FAIL={shlex.quote('|'.join(measured_fail))}")


if __name__ == "__main__":
    main()
