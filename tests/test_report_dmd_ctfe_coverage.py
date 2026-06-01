from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def load_report_module():
    script = Path(__file__).parents[1] / "scripts" / "report-dmd-ctfe-coverage.py"
    spec = importlib.util.spec_from_file_location("report_dmd_ctfe_coverage", script)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_parse_coverage_restores_enclosing_function_after_nested_helper(tmp_path):
    report = load_report_module()
    listing = tmp_path / "dmd-dinterpret.lst"
    listing.write_text(
        """\
        |Expression outer()
        |{
0000000|    auto before = 1;
        |    Expression inner()
        |    {
0000000|        return null;
        |    }
0000000|    return inner();
        |}
""",
        encoding="utf-8",
    )

    areas, _, _ = report.parse_coverage(listing)

    assert areas["Expression outer()"].uncovered == 2
    assert areas["Expression inner()"].uncovered == 1
