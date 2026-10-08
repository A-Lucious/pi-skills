#!/usr/bin/env python3
from __future__ import annotations

import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))


if __name__ == "__main__":
    main = importlib.import_module("shopping_aggregator.cli").main
    raise SystemExit(main())
