#!/usr/bin/env python3
"""Прогон порта h1-x12-st. См. python -m backtester.cli alchemist --help."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backtester.cli import main

if __name__ == "__main__":
    main(["alchemist", *sys.argv[1:]])
