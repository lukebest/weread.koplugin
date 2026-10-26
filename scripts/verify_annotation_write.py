#!/usr/bin/env python3
"""Verify WeRead Web write endpoints for bookmarks, thoughts, and finish status.

Script-first validation for the closed-source-parity features: before any Lua
implementation, this script proves the endpoints, required headers, and
signatures against a real account, then cleans up what it created.

Reads credentials from KOReader's ``settings/weread.lua`` (never printed).
Every mode only touches a book you choose via ``--book-id``; pass
``--yes`` to confirm writes. Endpoints are probed in this order:

  --probe      reachability check for each candidate endpoint (no writes)
  --bookmark   addBookmark -> read back via Gateway bookmarklist -> delete
  --thought    addReview   -> read back via own review list -> delete
  --mark-read  mark-read variants -> verify finishTime via Gateway getprogress

Usage: python3 scripts/verify_annotation_write.py --settings settings/weread.lua \
           --book-id 12345 --bookmark --yes
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from fetch_weread_epub import sorted_query, weread_e, weread_sign
from verify_progress_sync import load_settings

READER_URL = "https://weread.qq.com/web/reader/{book}"
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "120.0.0.0 Safari/537.36"
)


class Client:
    def __init__(self, settings: dict[str, Any]) -> None:
        cookies = settings["cookies"]
        self.cookie_header = "; ".join(
            f"{name}={value}" for name, value in cookies.items()
        )
        self.api_key = settings["api_key"]

    def web_get(self, path: str, params: dict[str, Any]) -> dict[str, Any]:
        query = dict(params)
        if "s" not in query:
            query["s"] = weread_sign(sorted_query({k: v for k, v in query.items()}))
        url = f"https://weread.qq.com{path}?{urllib.parse.urlencode(query)}"
        request = urllib.request.Request(url, headers={
            "Cookie": self.cookie_header,
            "User-Agent": UA,
            "Referer": "https://weread.qq.com/",
        })
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))

    def web_post_json(self, path: str, payload: dict[str, Any],
                      book_id: str) -> dict[str, Any]:
        url = f"https://weread.qq.com{path}"
        body = dict(payload)
        if "s" not in body:
            body["s"] = weread_sign(sorted_query(body))
        request = urllib.request.Request(
            url, data=json.dumps(body).encode("utf-8"), headers={
                "Cookie": self.cookie_header,
                "User-Agent": UA,
                "Content-Type": "application/json;charset=UTF-8",
                "Origin": "https://weread.qq.com",
                "Referer": READER_URL.format(book=weread_e(book_id) + "k780"),
            })
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))

    def gateway(self, api_name: str, params: dict[str, Any]) -> dict[str, Any]:
        request = urllib.request.Request(
            "https://i.weread.qq.com/api/agent/gateway",
            data=json.dumps({
                "api_name": api_name, "skill_version": "1.0.3", **params,
            }).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            })
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))


def probe(client: Client) -> None:
    candidates = [
        ("addBookmark", "/web/book/addbookmark", {"bookId": "", "chapterUid": ""}),
        ("addReview", "/web/review/addReview", None),
        ("markread", "/web/book/markread", {"bookId": ""}),
        ("finish", "/web/book/finish", {"bookId": ""}),
        ("dict", "/web/book/dict", {"word": ""}),
    ]
    for name, path, params in candidates:
        try:
            if params is None:
                result = {"errCode": "post-shape (payload required)"}
            else:
                result = client.web_get(path, params)
            print(f"probe {name:12} {path:28} -> {result}")
        except Exception as error:  # noqa: BLE001 - probe reports anything
            print(f"probe {name:12} {path:28} -> {type(error).__name__}: {error}")
        time.sleep(0.3)


def run_bookmark(client: Client, book_id: str) -> None:
    chapter = client.gateway("/book/info", {"bookId": book_id}) or {}
    chapter_uid = (chapter.get("firstChapterUid")
                   or (chapter.get("chapters") or [{}])[0].get("chapterUid"))
    payload = {"bookId": book_id, "chapterUid": chapter_uid, "chapterOffset": 0,
               "range": "0-3", "colorStyle": 0, "type": 1}
    created = client.web_get("/web/book/addbookmark", payload)
    print("addBookmark ->", created)
    listing = client.gateway("/book/bookmarklist", {"bookId": book_id})
    marks = (listing.get("updated") or [])
    mine = [m for m in marks if m.get("markText") == "" or m.get("range") == "0-3"]
    print(f"read-back: {len(marks)} bookmarks, probe matches: {len(mine)}")
    for mark in mine:
        deleted = client.web_get("/web/book/deletebookmark",
                                 {"bookmarkId": mark["bookmarkId"]})
        print("deleteBookmark ->", deleted)
        time.sleep(0.3)


def run_thought(client: Client, book_id: str) -> None:
    import random
    stamp = f"verify script {random.randint(1000, 9999)}"
    payload = {"bookId": book_id, "chapterUid": 1, "chapterName": "",
               "range": "0-3", "content": stamp, "adjustReplyId": 0}
    created = client.web_post_json("/web/review/addReview", payload, book_id)
    print("addReview ->", created)
    listing = client.gateway("/review/list", {
        "bookId": book_id, "reviewListType": 3, "count": 20})
    reviews = listing.get("reviews") or []
    match = next((r for r in reviews
                  if stamp in json.dumps(r.get("review", {}), ensure_ascii=False)), None)
    print("read-back match:", bool(match))
    if match:
        review = match["review"]
        deleted = client.web_get("/web/review/deletereview",
                                 {"reviewId": review.get("reviewId"),
                                  "listType": 3})
        print("deleteReview ->", deleted)


def run_mark_read(client: Client, book_id: str) -> None:
    for path in ("/web/book/markread", "/web/book/finish"):
        try:
            result = client.web_get(path, {"bookId": book_id})
        except Exception as error:  # noqa: BLE001
            print(f"{path} -> {type(error).__name__}: {error}")
            continue
        print(f"{path} ->", result)
        progress = client.gateway("/book/getprogress", {"bookId": book_id})
        finish = (progress.get("book") or {}).get("finishTime")
        print(f"  finishTime now: {finish}")
        if finish:
            break
        time.sleep(0.5)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", type=Path, default=Path("settings/weread.lua"))
    parser.add_argument("--book-id")
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--bookmark", action="store_true")
    parser.add_argument("--thought", action="store_true")
    parser.add_argument("--mark-read", action="store_true")
    parser.add_argument("--yes", action="store_true",
                        help="Confirm that writes to the chosen book are allowed")
    args = parser.parse_args()
    if not (args.probe or args.bookmark or args.thought or args.mark_read):
        parser.error("choose at least one of --probe/--bookmark/--thought/--mark-read")
    settings = load_settings(args.settings)
    client = Client(settings)
    if args.probe:
        probe(client)
    book_id = str(args.book_id or settings.get("default_book_id") or "")
    if not args.probe:
        if not book_id:
            print("error: --book-id is required for write modes", file=sys.stderr)
            return 2
        if not args.yes:
            print(f"error: writes need --yes (book {book_id})", file=sys.stderr)
            return 2
    if args.bookmark:
        run_bookmark(client, book_id)
    if args.thought:
        run_thought(client, book_id)
    if args.mark_read:
        run_mark_read(client, book_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
