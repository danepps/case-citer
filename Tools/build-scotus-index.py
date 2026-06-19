#!/usr/bin/env python3
"""Build the bundled SCOTUS citation index for Case Citer.

Pages CourtListener's v4 search API (the only endpoint that orders by citation
count) and writes the top-N most-cited, *citeable* Supreme Court opinions to
`Sources/App/Resources/scotus-index.json`. Each record matches the app's
`CourtListener.SearchResult` Codable shape, so the app loads it with zero extra
model code and runs it through the same isCiteable -> CaseRecord -> formatter path.

Why top-by-citeCount: CL's SCOTUS corpus is ~500k opinions, almost all obscure
orders/per-curiam dispositions. The most-cited slice is a few MB and covers every
case anyone actually cites; the long tail falls through to the live network search.

Usage:
    python3 Tools/build-scotus-index.py [LIMIT]      # default LIMIT = 20000

Auth: reuses the app's stored token (`defaults read -g courtListenerAPIKey`), or
the CL_TOKEN env var. Anonymous works but is throttled harder.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

API = "https://www.courtlistener.com/api/rest/v4/search/"
OUT = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "Sources", "App", "Resources", "scotus-index.json")
)

# A record is worth bundling only if it carries a citation to an official or major
# parallel reporter — otherwise it can't yield a Bluebook cite (mirrors the app's
# SearchResult.isCiteable, kept deliberately loose; the app re-checks at format time).
CITEABLE_RE = re.compile(r"^\d+\s+(U\.S\.|S\. ?Ct\.|L\. ?Ed\.)")


def citeable(cites):
    return any(CITEABLE_RE.match(c.strip()) for c in (cites or []))


def token():
    try:
        t = subprocess.check_output(
            ["defaults", "read", "-g", "courtListenerAPIKey"], text=True, stderr=subprocess.DEVNULL
        ).strip()
        if t:
            return t
    except Exception:
        pass
    return os.environ.get("CL_TOKEN")


def fetch(url, headers, attempts=8):
    """GET `url`, returning parsed JSON. Retries with backoff; honors the server's
    Retry-After on 429 (the CL search endpoint throttles aggressively). Raises only
    after exhausting `attempts` — callers checkpoint progress so that's recoverable."""
    req = urllib.request.Request(url, headers=headers)
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = int(e.headers.get("Retry-After") or 0) or min(60, 5 * (attempt + 1))
                sys.stderr.write(f"\n  429 rate-limited; sleeping {wait}s\n")
                time.sleep(wait)
                continue
            if attempt == attempts - 1:
                raise
            time.sleep(2 * (attempt + 1))
        except Exception as e:
            if attempt == attempts - 1:
                raise
            sys.stderr.write(f"\n  retry after error: {e}\n")
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"giving up after {attempts} attempts: {url}")


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    headers = {"User-Agent": "CaseCiter-index-builder/1.0"}
    tok = token()
    if tok:
        headers["Authorization"] = f"Token {tok}"
    else:
        sys.stderr.write("warning: no API token; anonymous requests are throttled harder\n")

    params = {"type": "o", "court": "scotus", "order_by": "citeCount desc"}
    url = API + "?" + urllib.parse.urlencode(params)

    def save(out):
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        tmp = OUT + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, OUT)

    seen = set()
    out = []
    pages = 0
    try:
        while url and len(out) < limit:
            data = fetch(url, headers)
            for res in data.get("results", []):
                cid = res.get("cluster_id")
                if cid in seen:
                    continue
                seen.add(cid)
                cites = res.get("citation") or []
                if not citeable(cites):
                    continue
                out.append({
                    "caseName": res.get("caseName"),
                    "court": res.get("court"),
                    "court_id": res.get("court_id"),
                    "dateFiled": res.get("dateFiled"),
                    "docketNumber": res.get("docketNumber"),
                    "citation": cites,
                })
                if len(out) >= limit:
                    break
            pages += 1
            url = data.get("next")
            sys.stderr.write(f"\rpage {pages}: kept {len(out)} / scanned {len(seen)}")
            sys.stderr.flush()
            if pages % 25 == 0:  # checkpoint so a later crash can't lose everything
                save(out)
            time.sleep(1.0)  # the search endpoint throttles hard; stay under it
    finally:
        # Always persist what we have — a partial index still beats none, and the run
        # is resumable in spirit (re-running rebuilds from the top).
        save(out)
        size_mb = os.path.getsize(OUT) / 1_048_576
        sys.stderr.write(f"\nwrote {len(out)} records ({size_mb:.1f} MB) to {OUT}\n")


if __name__ == "__main__":
    main()
