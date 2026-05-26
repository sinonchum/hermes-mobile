#!/usr/bin/env python3
"""Hermes Bridge Server — Entry point wrapper.

This file is a thin wrapper that imports and runs the modular bridge server.
The actual implementation lives in bridge/ package.
"""

import sys
import os

# Add the assets directory to Python path so bridge package can be imported
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bridge.main import main

if __name__ == "__main__":
    main()
