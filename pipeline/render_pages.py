"""Render the legal/support page templates (web/*.html) into the Pages site.

Contact details come from the CONTACT_EMAIL / CONTACT_NAME environment variables (GitHub repo
variables in CI); they are never stored in the repo. Missing or invalid values never fail the run
(that would stop the nightly schedule publication): a neutral fallback text is used and a warning
is printed.
"""

import html
import os
import re
import sys
from pathlib import Path

FALLBACK = "el contacto que figura en la ficha de la tienda"
NAME_FALLBACK = "el desarrollador de la app"
_EMAIL = re.compile(r"^[^@\s<>\"]+@[^@\s<>\"]+\.[^@\s<>\"]+$")
_MAILTO = re.compile(r'<a href="mailto:\$\{CONTACT_EMAIL\}">\$\{CONTACT_EMAIL\}</a>')


def render(template: str, env: dict) -> tuple:
    """Return (html, warnings)."""
    warnings = []
    email = (env.get("CONTACT_EMAIL") or "").strip()
    name = (env.get("CONTACT_NAME") or "").strip()
    if not email:
        warnings.append("CONTACT_EMAIL is not set")
    elif not _EMAIL.match(email):
        warnings.append("CONTACT_EMAIL does not look like an email")
        email = ""
    if not name:
        warnings.append("CONTACT_NAME is not set")

    if email:
        e = html.escape(email, quote=True)
        out = _MAILTO.sub(lambda _: f'<a href="mailto:{e}">{e}</a>', template)  # callable: no backslash escapes
        out = out.replace("${CONTACT_EMAIL}", e)
    else:
        out = _MAILTO.sub(lambda _: FALLBACK, template)  # no broken mailto: link
        out = out.replace("${CONTACT_EMAIL}", FALLBACK)
    out = out.replace("${CONTACT_NAME}", html.escape(name) if name else NAME_FALLBACK)
    return out, warnings


def main(argv=None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 2:
        print("usage: render_pages.py SRC_DIR OUT_DIR", file=sys.stderr)
        return 2
    src, dst = Path(args[0]), Path(args[1])
    dst.mkdir(parents=True, exist_ok=True)
    for page in sorted(src.glob("*.html")):
        out, warnings = render(page.read_text(encoding="utf-8"), os.environ)
        for w in warnings:
            print(f"warning: {page.name}: {w}", file=sys.stderr)
        (dst / page.name).write_text(out, encoding="utf-8")
        print(f"rendered {page.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
