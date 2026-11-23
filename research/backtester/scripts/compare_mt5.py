#!/usr/bin/env python3
"""Сверка списка сделок с отчётом MT5. См. python -m backtester.cli compare --help."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backtester.cli import main

if __name__ == "__main__":
    main(["compare", *sys.argv[1:]])
