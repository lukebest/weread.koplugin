# WeRead progress sync: precise-position research plan

Status: research pending. The Lua groundwork is merged behind
`sync.precise_position` (default **off**); enabling it broadly requires the
calibration below to pass on a real account.

## Goal

Replace word-based "approximate" progress sync with character-level mapping
(closed-source-parity row: 精确阅读进度). Two open questions decide feasibility:

1. **What does the server's `pr` (0-100 progress) divide?** Hypothesis:
   `pr = floor((chars-before-chapter + chapterOffset) / total-chars × 100)`
   where chars are counted on the plain chapter text. The denominator may
   instead be `wordCount`-derived or skip front-matter chapters.
2. **What unit is `co` (chapterOffset)?** Candidates: plain-text runes,
   source-HTML runes including tags (the underline `range` basis, see
   `weread/lib/annotations.lua`), or wordCount-scaled.

## Procedure (extend `scripts/verify_progress_sync.py`)

- `--calibrate-pr`: for 5-10 known `(chapterUid, chapterOffset)` anchors in
  one book, upload via `/web/book/read` (rt=0), pull Gateway
  `/book/getprogress`, and fit the observed `pr` against each candidate
  formula. Report per-anchor error; target max |error| < 0.5.
- `--offset-model`: upload offsets computed by each candidate basis, then
  read back `chapterOffset`/`progress` and compare round-trip deltas
  (the existing `--round-trip-write`/`--probe-distance` machinery is the
  harness for this).
- Record the fitted formula, the measured round-trip error, and the chosen
  basis here before flipping the default.

## Current implementation notes

- `weread/lib/position_mapper.lua` catalogs measure an explicit unit:
  `chars` when every chapter carries `charCount`, else `words`; positions
  report `position_unit`, remote progress reports `position_unit` on the
  chapter-offset basis.
- `weread/lib/chapter_char_counts.lua` counts runes over the text spans of
  annotation-store "original" sources (plain-text basis, entities
  unresolved — a known gap if calibration proves the HTML-rune basis; the
  spans' offsets preserve full-HTML runes and can supply that basis).
- `sync.precise_position` gates enrichment + chars mode; the menu toggle
  lives under Settings → Progress management (experimental).

## Degradation ladder

characters → words (current default) → chapter-level (uid + raw percent).
Any chapter without a counted source falls the whole book one step down.
