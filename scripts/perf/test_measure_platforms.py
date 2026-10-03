"""Fake exec only: verify the original shared measurer's selected platform."""
import os
from pathlib import Path
import runpy
import sys
import unittest
from unittest.mock import patch

ENTRY = Path(__file__).with_name("measure_platforms.py")


class PlatformDefaultTests(unittest.TestCase):
    def command(self, args=(), environment=None):
        with patch.dict(os.environ, environment or {}, clear=True), \
                patch.object(sys, "argv", [str(ENTRY), *args]), \
                patch("os.execv") as execute:
            runpy.run_path(str(ENTRY), run_name="__main__")
        execute.assert_called_once()
        return execute.call_args.args[1]

    def test_default_all_and_persisted_single_platform(self):
        default = self.command()
        selected = self.command(environment={"SOP_PERF_PLATFORM": "ipad"})
        self.assertEqual(default[-2:], ["--platform", "all"])
        self.assertEqual(selected[-2:], ["--platform", "ipad"])
        self.assertEqual(default[:-2], selected[:-2])
        self.assertIn("hydro-deck", selected)

    def test_explicit_platform_overrides_environment(self):
        for args in (("--platform", "mac"), ("--platform=mac",)):
            with self.subTest(args=args):
                command = self.command(args, {"SOP_PERF_PLATFORM": "invalid"})
                self.assertEqual(command[-len(args):], list(args))
                self.assertNotIn("invalid", command)
                self.assertNotIn("all", command)

    def test_invalid_environment_stops_before_exec(self):
        with patch.dict(os.environ, {"SOP_PERF_PLATFORM": "watch"}, clear=True), \
                patch.object(sys, "argv", [str(ENTRY)]), patch("os.execv") as execute:
            with self.assertRaises(SystemExit):
                runpy.run_path(str(ENTRY), run_name="__main__")
        execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
