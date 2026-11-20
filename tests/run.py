#!/usr/bin/env python3
"""Run the Luau unit tests in tests/test_*.luau against umbriel-shaders/lib.

Noctalia requires modules as require("./x.luau"); the stock luau CLI resolves
require("./x"). The lib modules are copied to a temporary tree with the
extension removed, next to a copy of the tests, so tests can require("../lib/x").
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRE = re.compile(r'require\("(\.{1,2}/[^"]+)\.luau"\)')


def main() -> int:
    luau = sys.argv[1] if len(sys.argv) > 1 else "luau"
    with tempfile.TemporaryDirectory(prefix="umbriel-shaders-tests-") as temp:
        tree = Path(temp)
        (tree / "lib").mkdir()
        for module in (ROOT / "umbriel-shaders" / "lib").glob("*.luau"):
            (tree / "lib" / module.name).write_text(REQUIRE.sub(r'require("\1")', module.read_text()))
        shutil.copytree(ROOT / "tests", tree / "tests", ignore=shutil.ignore_patterns("*.py", "__pycache__"))
        failures = 0
        for test in sorted((tree / "tests").glob("test_*.luau")):
            failures += subprocess.run([luau, str(test)]).returncode != 0
    if failures:
        print(f"{failures} test file(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
