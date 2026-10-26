-- Character-mode catalog mapping for precise progress sync.

package.path = "./?.lua;" .. package.path

local PositionMapper = require("weread.lib.position_mapper")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local chapters = {
    { chapterUid = 1, wordCount = 10, charCount = 40 },
    { chapterUid = 2, wordCount = 20, charCount = 60 },
    { chapterUid = 3, wordCount = 30, charCount = 100 },
}

-- Word mode stays the default when char counts are absent.
local word_map = PositionMapper.catalog(chapters, { unit = "words" })
expect(word_map.unit == "words", "word mode keeps the words unit")
expect(word_map.total == 60 and word_map.chapters[2].before == 10,
    "word mode accumulates word counts")

-- Chars mode: any chapter missing charCount falls the whole book back.
local mixed = {
    { chapterUid = 1, wordCount = 10, charCount = 40 },
    { chapterUid = 2, wordCount = 20 },
}
local mixed_map = PositionMapper.catalog(mixed, { unit = "chars" })
expect(mixed_map.unit == "words",
    "a missing char count falls the whole catalog back to words")

local char_map = PositionMapper.catalog(chapters, { unit = "chars" })
expect(char_map.unit == "chars", "complete char counts enable chars mode")
expect(char_map.total == 200, "chars mode accumulates rune counts")
expect(char_map.chapters[2].before == 40 and char_map.chapters[3].before == 100,
    "chars mode accumulates per-chapter rune counts")

-- Local → remote mapping measures chapter offsets in the active unit.
local position = PositionMapper.local_to_remote(chapters, 0.3, {
    catalog = char_map,
    is_full_book = true,
})
expect(position.chapter_uid == 2, "the 30% point lands in chapter two")
expect(position.chapter_offset == 20,
    "the offset is measured in runes (20 runes into a 60-rune chapter)")
expect(position.position_unit == "chars", "the position reports its unit")
expect(position.percent == 30, "the percent matches the overall fraction")

-- Word catalog on the same fraction measures offsets in words.
local word_position = PositionMapper.local_to_remote(chapters, 0.4, {
    catalog = word_map,
    is_full_book = true,
})
expect(word_position.chapter_offset == 14,
    "the word catalog keeps word-based offsets")
expect(word_position.position_unit == "words",
    "word positions report the words unit")

-- Remote → local: rune offsets resolve through the same unit.
local local_position = PositionMapper.remote_to_local(chapters, {
    chapter_uid = 3,
    chapter_offset = 50,
    percent = 50,
}, { unit = "chars" })
expect(local_position ~= nil and local_position.fraction == 0.5,
    "rune offsets divide through the chapter's rune count")

-- Enriched chapters: the mapper consumes charCount set by the scan helper.
local enriched = {
    { chapterUid = 1, wordCount = 10, charCount = 5 },
}
local enriched_map = PositionMapper.catalog(enriched, { unit = "chars" })
expect(enriched_map.total == 5, "pre-counted chapters are used as-is")

print("position_mapper_chars_spec passed (" .. checks .. " checks)")
