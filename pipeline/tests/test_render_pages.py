import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from render_pages import FALLBACK, render  # noqa: E402

SCRIPT = Path(__file__).resolve().parent.parent / "render_pages.py"
TEMPLATE = "<p>${CONTACT_NAME} · <a href=\"mailto:${CONTACT_EMAIL}\">${CONTACT_EMAIL}</a></p>"


class RenderPagesTest(unittest.TestCase):
    def test_substitutes_with_html_escape(self):
        out, warnings = render(TEMPLATE, {"CONTACT_NAME": "Ana & <Luis>", "CONTACT_EMAIL": "ana@example.org"})
        self.assertIn("Ana &amp; &lt;Luis&gt;", out)
        self.assertIn('mailto:ana@example.org', out)
        self.assertEqual([], warnings)
        self.assertNotIn("${", out)

    def test_missing_variable_uses_fallback_and_warns(self):
        out, warnings = render(TEMPLATE, {"CONTACT_NAME": "Ana"})
        self.assertIn(FALLBACK, out)
        self.assertNotIn("mailto:", out)  # no broken link
        self.assertTrue(any("CONTACT_EMAIL" in w for w in warnings))
        self.assertNotIn("${", out)

    def test_backslash_in_email_never_crashes(self):
        out, _ = render(TEMPLATE, {"CONTACT_NAME": "Ana", "CONTACT_EMAIL": "us\\1er@example.org"})
        self.assertNotIn("${", out)

    def test_invalid_email_uses_fallback(self):
        out, warnings = render(TEMPLATE, {"CONTACT_NAME": "Ana", "CONTACT_EMAIL": "not an email"})
        self.assertNotIn("not an email", out)
        self.assertIn(FALLBACK, out)
        self.assertTrue(warnings)

    def test_cli_renders_directory_and_never_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp) / "web", Path(tmp) / "site"
            src.mkdir()
            (src / "a.html").write_text(TEMPLATE, encoding="utf-8")
            env = {k: v for k, v in os.environ.items() if not k.startswith("CONTACT_")}
            proc = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)], capture_output=True, text=True, env=env)
            self.assertEqual(0, proc.returncode, proc.stderr)
            self.assertIn("warning", proc.stderr)
            self.assertNotIn("${", (dst / "a.html").read_text(encoding="utf-8"))

    def test_cli_copies_icons_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp) / "web", Path(tmp) / "site"
            src.mkdir()
            (src / "favicon.ico").write_bytes(b"\x00\x00\x01\x00${CONTACT_EMAIL}")
            (src / "favicon.png").write_bytes(b"\x89PNG")
            (src / "legal.css").write_text("h2 { }")
            proc = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)], capture_output=True, text=True)
            self.assertEqual(0, proc.returncode, proc.stderr)
            self.assertEqual(b"\x00\x00\x01\x00${CONTACT_EMAIL}", (dst / "favicon.ico").read_bytes())
            self.assertEqual(b"\x89PNG", (dst / "favicon.png").read_bytes())
            self.assertEqual("h2 { }", (dst / "legal.css").read_text())


if __name__ == "__main__":
    unittest.main()
