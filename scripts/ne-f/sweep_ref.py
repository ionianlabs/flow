"""Runs asr/sweep.py as the parity reference for the Swift sweep, with the clock fixed.

  python -I sweep_ref.py --now EPOCH --today YYYY-MM-DD [sweep.py arguments]

Same as `python sweep.py ...` (use --cache and --out: never the defaults), except that "now" (the
recency of notes) and "today" (the heading) are what the Swift run is given, so the outputs can be
compared byte for byte.
"""

import os
import sys
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "asr"))

args = sys.argv[1:]
now = float(args.pop(args.index("--now") + 1)); args.remove("--now")
today = args.pop(args.index("--today") + 1); args.remove("--today")

import sweep  # noqa: E402

sweep.time = types.SimpleNamespace(time=lambda: now, perf_counter=time.perf_counter)


class _Date:
    @staticmethod
    def today():
        return types.SimpleNamespace(isoformat=lambda: today)


sweep.date = _Date
sys.argv = ["sweep.py"] + args
sweep.main()
