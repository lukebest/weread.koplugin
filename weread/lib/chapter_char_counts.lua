-- Per-chapter rune counts for precise progress mapping.
--
-- Counts UTF-8 runes on the text spans of cached chapter sources (the
-- annotation store's "original" rows). Counted values are written back onto
-- the chapter records so the scan happens once per chapter; books whose
-- chapters lack cached sources stay on word-based mapping.

local logger = require("weread.lib.logger")

local M = {}

local function rune_length(text)
    local count, index = 0, 1
    while index <= #text do
        local byte = text:byte(index)
        if byte < 128 then index = index + 1
        elseif byte < 224 then index = index + 2
        elseif byte < 240 then index = index + 3
        else index = index + 4 end
        count = count + 1
    end
    return count
end

-- Returns the chapter list with charCount set on every chapter, or nil with
-- a reason when any chapter has no cached source.
function M.enrich(settings, book_id, chapters)
    if type(chapters) ~= "table" or #chapters == 0 then
        return nil, "catalog_unavailable"
    end
    local ok_store, Store = pcall(require, "weread.lib.annotation_store")
    if not ok_store then return nil, "store_unavailable" end
    local store
    local ok_new = pcall(function()
        store = Store:new(settings)
    end)
    if not ok_new or not store then
        return nil, "store_unavailable"
    end
    for _i, chapter in ipairs(chapters) do
        if chapter.charCount == nil then
            local uid = tostring(chapter.chapterUid or chapter.chapterId or "")
            local ok_value, spans = pcall(function()
                return store:get(book_id, "original", uid)
            end)
            local count
            if ok_value and type(spans) == "table" then
                count = 0
                for _span, span in ipairs(spans) do
                    count = count + rune_length(tostring(span[3] or ""))
                end
            end
            if count == nil then
                logger.info("char count source missing:", "book=", tostring(book_id),
                    "chapter=", uid)
                return nil, "chapter_source_missing"
            end
            chapter.charCount = count
        end
    end
    return chapters
end

return M
