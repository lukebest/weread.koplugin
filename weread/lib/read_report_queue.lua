-- SQLite queue for reading-time reports recorded while offline.
--
-- Rows are bounded in count, age, and per-entry seconds so a device that
-- stays offline for weeks cannot grow the queue indefinitely, and every
-- replayed payload stays close to what the Web reader itself would have
-- sent. Time recorded offline is credited to the day it is uploaded.

local logger = require("weread.lib.logger")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local ReadReportQueue = {}
ReadReportQueue.__index = ReadReportQueue

-- Hard bounds (code constants, not settings): ~500 replays max, entries
-- older than a week are dropped, and one replay never claims more than
-- two minutes at once so the payload stays unremarkable.
local DEFAULT_MAX_ROWS = 500
local DEFAULT_MAX_AGE_DAYS = 7
local DEFAULT_SINGLE_RT_CAP = 120
local DEFAULT_MAX_ATTEMPTS = 5
local DEFAULT_MERGE_WINDOW_SECONDS = 60

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    return ok and SQ3 or nil
end

local function encode(value)
    if not ok_json then return nil end
    local ok, result = pcall(function()
        return json.encode and json.encode(value) or json:encode(value)
    end)
    return ok and result or nil
end

local function decode(value)
    if type(value) ~= "string" or value == "" or not ok_json then return nil end
    local ok, result = pcall(function()
        return json.decode and json.decode(value) or json:decode(value)
    end)
    return ok and type(result) == "table" and result or nil
end

local function close_statement(stmt)
    if stmt then pcall(function() stmt:close() end) end
end

function ReadReportQueue:new(settings, options)
    options = options or {}
    local data_dir = settings.data_dir or settings.cache_dir or "."
    return setmetatable({
        data_dir = tostring(data_dir),
        path = data_dir .. "/read-report-queue.db",
        now = options.now or os.time,
        max_rows = options.max_rows or DEFAULT_MAX_ROWS,
        max_age_days = options.max_age_days or DEFAULT_MAX_AGE_DAYS,
        single_rt_cap = options.single_rt_cap or DEFAULT_SINGLE_RT_CAP,
        max_attempts = options.max_attempts or DEFAULT_MAX_ATTEMPTS,
        merge_window = options.merge_window or DEFAULT_MERGE_WINDOW_SECONDS,
    }, self)
end

function ReadReportQueue:available()
    return getSQ3() ~= nil and ok_json
end

function ReadReportQueue:open()
    if not self:available() then
        return nil
    end
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.attributes(self.data_dir, "mode") then
        local created, mkdir_err = lfs.mkdir(self.data_dir)
        if not created and not lfs.attributes(self.data_dir, "mode") then
            return nil, tostring(mkdir_err or "queue directory creation failed")
        end
    end
    local SQ3 = getSQ3()
    local ok, db = pcall(SQ3.open, self.path)
    if not ok or not db then
        return nil, tostring(db or "queue database open failed")
    end
    local schema_ok, schema_err = pcall(function()
        db:exec("PRAGMA journal_mode=WAL")
        db:exec("PRAGMA synchronous=NORMAL")
        db:exec([[
            CREATE TABLE IF NOT EXISTS pending_reports (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id    TEXT NOT NULL,
                rt         INTEGER NOT NULL,
                snapshot   TEXT,
                created_at INTEGER NOT NULL,
                attempts   INTEGER NOT NULL DEFAULT 0
            )
        ]])
    end)
    if not schema_ok then
        pcall(function() db:close() end)
        return nil, tostring(schema_err)
    end
    return db
end

local function with_db(self, fn)
    local db = self:open()
    if not db then
        return false, "queue database unavailable"
    end
    local ok, result, err = pcall(fn, db)
    pcall(function() db:close() end)
    if not ok then
        return false, tostring(result)
    end
    if result == false then
        return false, err
    end
    return true, result
end

local function prune_rows(db, cutoff, max_attempts)
    local stmt = db:prepare(
        "DELETE FROM pending_reports WHERE created_at < ? OR attempts >= ?")
    stmt:reset():bind(cutoff, max_attempts):step()
    close_statement(stmt)
end

local function count_rows(db)
    local stmt = db:prepare("SELECT COUNT(*) FROM pending_reports")
    local row = stmt:reset():step()
    local count = tonumber(row and row[1] or 0)
    stmt:close()
    return count
end

-- Add offline reading time. Consecutive ticks for the same book merge into
-- one entry until the merge window lapses or the per-entry cap would be
-- exceeded; otherwise a fresh entry is started. Enqueue also prunes entries
-- that are too old or have failed too often — their reading time is lost,
-- which the bounds above keep small and predictable.
function ReadReportQueue:enqueue(book_id, rt, position)
    book_id = tostring(book_id or "")
    rt = math.max(0, math.floor(tonumber(rt) or 0))
    if book_id == "" or rt <= 0 then
        return false, "invalid entry"
    end
    if not self:available() then
        return false, "queue unavailable"
    end
    local snapshot = position and encode(position) or nil
    local now = self.now()
    local merge_cutoff = now - self.merge_window
    local cutoff = now - self.max_age_days * 86400
    return with_db(self, function(db)
        prune_rows(db, cutoff, self.max_attempts)
        local merged = false
        local find = db:prepare([[
            SELECT id FROM pending_reports
            WHERE book_id = ? AND created_at >= ? AND rt + ? <= ?
            ORDER BY created_at DESC, id DESC LIMIT 1
        ]])
        local row = find:reset():bind(book_id, merge_cutoff, rt, self.single_rt_cap):step()
        close_statement(find)
        if row then
            local update = db:prepare(
                "UPDATE pending_reports SET rt = rt + ?, created_at = ?, snapshot = ? WHERE id = ?")
            update:reset():bind(rt, now, snapshot, row[1]):step()
            close_statement(update)
            merged = true
        end
        if not merged then
            local count = count_rows(db)
            if count >= self.max_rows then
                -- Keep the bound: drop the oldest entries to make room.
                local evict = db:prepare([[
                    DELETE FROM pending_reports WHERE id IN (
                        SELECT id FROM pending_reports ORDER BY created_at, id LIMIT ?
                    )
                ]])
                evict:reset():bind(count - self.max_rows + 1):step()
                close_statement(evict)
            end
            local insert = db:prepare([[
                INSERT INTO pending_reports (book_id, rt, snapshot, created_at)
                VALUES (?, ?, ?, ?)
            ]])
            insert:reset():bind(book_id, rt, snapshot, now):step()
            close_statement(insert)
        end
        return true
    end)
end

-- Oldest-first batch for replay. Each entry decodes its position snapshot
-- (nil when none was captured; the pipeline then uses the stored position).
function ReadReportQueue:peek_batch(limit)
    limit = math.max(1, math.min(tonumber(limit) or 20, 100))
    local ok, result = with_db(self, function(db)
        local stmt = db:prepare([[
            SELECT id, book_id, rt, snapshot FROM pending_reports
            ORDER BY created_at, id LIMIT ?
        ]])
        local entries = {}
        local row = stmt:reset():bind(limit):step()
        while row do
            entries[#entries + 1] = {
                id = row[1],
                book_id = row[2],
                rt = tonumber(row[3]) or 0,
                position = decode(row[4]),
            }
            row = stmt:step()
        end
        close_statement(stmt)
        return entries
    end)
    if not ok then
        return {}
    end
    return result
end

function ReadReportQueue:delete(id)
    return with_db(self, function(db)
        local stmt = db:prepare("DELETE FROM pending_reports WHERE id = ?")
        stmt:reset():bind(id):step()
        close_statement(stmt)
        return true
    end)
end

-- Count a failed replay; entries that keep failing are pruned by attempts.
function ReadReportQueue:mark_failed(id, _error)
    return with_db(self, function(db)
        local stmt = db:prepare(
            "UPDATE pending_reports SET attempts = attempts + 1 WHERE id = ?")
        stmt:reset():bind(id):step()
        close_statement(stmt)
        return true
    end)
end

function ReadReportQueue:count()
    local ok, result = with_db(self, function(db)
        return count_rows(db)
    end)
    if not ok then
        return 0
    end
    return result
end

-- Manual maintenance entry point (enqueue prunes on its own).
function ReadReportQueue:prune()
    if not self:available() then
        return false, "queue unavailable"
    end
    local cutoff = self.now() - self.max_age_days * 86400
    return with_db(self, function(db)
        prune_rows(db, cutoff, self.max_attempts)
        return true
    end)
end

return ReadReportQueue
