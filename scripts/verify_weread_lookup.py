#!/usr/bin/env python3
"""Probe WeRead Web endpoints behind the in-app dictionary/baike lookup.

Script-first validation for the online-lookup feature: the Web reader calls
something when a word is selected, but the endpoint is undocumented. This
script probes candidates with a real word and reports which one returns
structured definitions; the Gateway full-text search (scope=12) is checked
as the fallback path.

Usage: python3 scripts/verify_weread_lookup.py --settings settings/weread.lua \
           --word 刻意 --book-id 12345
"""

from __future__ import annotations

import argparse
import json
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from verify_progress_sync import load_settings

UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "120.0.0.0 Safari/537.36"
)

CANDIDATES = [
    "/web/book/dict",
    "/web/dict/search",
    "/web/book/baike",
    "/web/search/baike",
    "/web/book/wordExplain",
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", type=Path, default=Path("settings/weread.lua"))
    parser.add_argument("--word", default="刻意")
    parser.add_argument("--book-id", default="")
    args = parser.parse_args()

    settings = load_settings(args.settings)
    cookies = "; ".join(f"{n}={v}" for n, v in settings["cookies"].items())

    def get(url: str) -> dict[str, Any]:
        request = urllib.request.Request(url, headers={
            "Cookie": cookies, "User-Agent": UA,
            "Referer": "https://weread.qq.com/",
        })
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))

    for path in CANDIDATES:
        params = {"word": args.word}
        if args.book_id:
            params["bookId"] = args.book_id
        url = f"https://weread.qq.com{path}?{urllib.parse.urlencode(params)}"
        try:
            body = get(url)
            text = json.dumps(body, ensure_ascii=False)
            print(f"{path:24} -> {text[:220]}")
        except Exception as error:  # noqa: BLE001 - probe reports anything
            print(f"{path:24} -> {type(error).__name__}: {error}")

    # Fallback: Gateway full-text search for in-book occurrences.
    request = urllib.request.Request(
        "https://i.weread.qq.com/api/agent/gateway",
        data=json.dumps({
            "api_name": "/store/search", "skill_version": "1.0.3",
            "keyword": args.word, "scope": 12, "count": 10,
        }).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {settings['api_key']}",
            "Content-Type": "application/json",
        })
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = json.loads(response.read().decode("utf-8"))
        text = json.dumps(body, ensure_ascii=False)
        print(f"{'gateway /store/search scope=12':24} -> {text[:220]}")
    except Exception as error:  # noqa: BLE001
        print(f"{'gateway /store/search scope=12':24} -> {type(error).__name__}: {error}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
