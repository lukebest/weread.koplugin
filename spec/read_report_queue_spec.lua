-- Focused tests for the offline read-report queue: merging, bounds,
-- degradation, and replay ordering.

package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

-- ------------------------------------------------------------------
-- Fake lua-ljsqlite3 that interprets exactly the statements the queue uses.
-- Handlers run lazily on the first step, after the caller has bound args.
-- ------------------------------------------------------------------
local rows = {}
local next_id = 1
local statements = {}

local function row_to_entry(row)
    return { row.id, row.book_id, row.rt, row.snapshot }
end

local function handler_for(sql)
    sql = sql:gsub("^%s+", "")
    for prefix, handler in pairs(statements) do
        if sql:sub(1, #prefix) == prefix then
            return handler
        end
    end
    error("queue spec: unexpected SQL: " .. sql)
end

local function make_stmt(sql)
    local stmt = { sql = sql, args = {} }
    local executed = false
    stmt.reset = function(current)
        current.args = {}
        return current
    end
    stmt.bind = function(current, ...)
        -- Bind values positionally; nil stays a real bound nil (ipairs
        -- would silently truncate the argument list at the first nil).
        local args, count = { ... }, select("#", ...)
        for index = 1, count do
            current.args[index] = tonumber(args[index]) or args[index]
        end
        return current
    end
    stmt.close = function() end
    local function default_step(current)
        if not executed then
            executed = true
            handler_for(sql)(current)
            -- The handler replaced step (multi-row or one-shot); delegate.
            return current.step(current)
        end
        return nil
    end
    stmt.step = default_step
    return stmt
end

statements["PRAGMA"] = function(stmt)
    stmt.step = function() return nil end
end
statements["CREATE TABLE"] = function(stmt)
    stmt.step = function() return nil end
end
statements["SELECT COUNT(*) FROM pending_reports"] = function(stmt)
    local served = false
    stmt.step = function()
        if served then return nil end
        served = true
        return { #rows }
    end
end
statements["SELECT id FROM pending_reports"] = function(stmt)
    local book_id, cutoff, rt, cap = stmt.args[1], stmt.args[2], stmt.args[3], stmt.args[4]
    local match
    for index = #rows, 1, -1 do
        local row = rows[index]
        if row.book_id == book_id and row.created_at >= cutoff
            and row.rt + rt <= cap then
            match = row
            break
        end
    end
    local served = false
    stmt.step = function()
        if served or not match then return nil end
        served = true
        return { match.id }
    end
end
statements["UPDATE pending_reports SET rt = rt + ?"] = function(stmt)
    local rt, created_at, snapshot, id = stmt.args[1], stmt.args[2], stmt.args[3], stmt.args[4]
    for _i, row in ipairs(rows) do
        if row.id == id then
            row.rt = row.rt + rt
            row.created_at = created_at
            row.snapshot = snapshot or row.snapshot
        end
    end
    stmt.step = function() return nil end
end
statements["UPDATE pending_reports SET attempts"] = function(stmt)
    local id = stmt.args[1]
    for _i, row in ipairs(rows) do
        if row.id == id then row.attempts = row.attempts + 1 end
    end
    stmt.step = function() return nil end
end
statements["DELETE FROM pending_reports WHERE id IN"] = function(stmt)
    local limit = stmt.args[1]
    table.sort(rows, function(a, b)
        if a.created_at ~= b.created_at then return a.created_at < b.created_at end
        return a.id < b.id
    end)
    while #rows > 0 and limit > 0 do
        table.remove(rows, 1)
        limit = limit - 1
    end
    stmt.step = function() return nil end
end
statements["DELETE FROM pending_reports WHERE created_at"] = function(stmt)
    local cutoff, max_attempts = stmt.args[1], stmt.args[2]
    local kept = {}
    for _i, row in ipairs(rows) do
        if row.created_at >= cutoff and row.attempts < max_attempts then
            kept[#kept + 1] = row
        end
    end
    rows = kept
    stmt.step = function() return nil end
end
statements["DELETE FROM pending_reports WHERE id = ?"] = function(stmt)
    local id = stmt.args[1]
    local kept = {}
    for _i, row in ipairs(rows) do
        if row.id ~= id then kept[#kept + 1] = row end
    end
    rows = kept
    stmt.step = function() return nil end
end
statements["INSERT INTO pending_reports"] = function(stmt)
    local book_id, rt, snapshot, created_at =
        stmt.args[1], stmt.args[2], stmt.args[3], stmt.args[4]
    rows[#rows + 1] = {
        id = next_id,
        book_id = book_id,
        rt = rt,
        snapshot = snapshot,
        created_at = created_at,
        attempts = 0,
    }
    next_id = next_id + 1
    stmt.step = function() return nil end
end
statements["SELECT id, book_id, rt, snapshot FROM pending_reports"] = function(stmt)
    local limit = stmt.args[1]
    local sorted = {}
    for _i, row in ipairs(rows) do sorted[#sorted + 1] = row end
    table.sort(sorted, function(a, b)
        if a.created_at ~= b.created_at then return a.created_at < b.created_at end
        return a.id < b.id
    end)
    local consumed = 0
    stmt.step = function()
        if consumed >= (limit or #sorted) then return nil end
        consumed = consumed + 1
        local row = sorted[consumed]
        if not row then return nil end
        return row_to_entry(row)
    end
end

local function fake_driver()
    return {
        open = function(_path)
            return {
                exec = function() end,
                prepare = function(_db, sql) return make_stmt(sql) end,
                close = function() end,
            }
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return "directory" end, mkdir = function() return true end }
end
local snapshots = {}
local next_snapshot = 0
package.preload["json"] = function()
    return {
        encode = function(value)
            next_snapshot = next_snapshot + 1
            snapshots[next_snapshot] = value
            return "snapshot-" .. next_snapshot
        end,
        decode = function(value)
            for index, stored in ipairs(snapshots) do
                if "snapshot-" .. index == value then return stored end
            end
            return nil
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end

local Queue = require("weread.lib.read_report_queue")
local clock = { value = 1000 }
local settings = { data_dir = "/data/weread" }
local function new_queue(options)
    options = options or {}
    return Queue:new(settings, {
        now = function() return clock.value end,
        max_rows = options.max_rows or 500,
        max_age_days = options.max_age_days or 7,
        single_rt_cap = options.single_rt_cap or 120,
        max_attempts = options.max_attempts or 5,
        merge_window = options.merge_window or 60,
    })
end

-- Degradation: without SQLite the queue reports itself unavailable and all
-- operations fail soft.
local degraded = new_queue()
expect(degraded:available() == false, "queue reports unavailable without sqlite")
expect(degraded:enqueue("1", 30) == false, "enqueue fails soft without sqlite")
expect(degraded:count() == 0, "count stays zero without sqlite")
expect(#degraded:peek_batch(10) == 0, "peek returns nothing without sqlite")

-- Re-enable the fake driver for the behavioral tests below.
package.preload["lua-ljsqlite3/init"] = fake_driver
local queue = new_queue()
expect(queue:available() == true, "queue reports available with sqlite")

-- Merge window: consecutive ticks for the same book accumulate into one row.
queue:enqueue("100", 30, { chapter_uid = 3 })
clock.value = clock.value + 30
queue:enqueue("100", 30, { chapter_uid = 4 })
expect(queue:count() == 1, "consecutive ticks merge into one entry")
local entries = queue:peek_batch(10)
expect(entries[1].rt == 60, "merged entry carries the summed seconds")
expect(entries[1].position ~= nil and entries[1].position.chapter_uid == 4,
    "merged entry keeps the latest position snapshot")

-- Per-entry cap: once merging would exceed the cap, a new row starts.
clock.value = clock.value + 30
queue:enqueue("100", 90)
expect(queue:count() == 2, "cap-exceeding tick starts a new entry")
entries = queue:peek_batch(10)
expect(entries[2].rt == 90, "the fresh entry holds the overflow seconds")
expect(entries[2].position == nil, "entries without a position decode to nil")

-- A lapse longer than the merge window also starts a new row.
clock.value = clock.value + 120
queue:enqueue("100", 30)
expect(queue:count() == 3, "a window lapse starts a new entry")

-- A different book never merges into the other book's row.
queue:enqueue("200", 30)
expect(queue:count() == 4, "different books use separate entries")

-- Replay order: oldest first.
entries = queue:peek_batch(2)
expect(entries[1].rt == 60 and entries[2].rt == 90, "replay batches are oldest-first")

-- Delete removes exactly one entry.
local removed_id = entries[1].id
queue:delete(removed_id)
expect(queue:count() == 3, "delete removes one entry")
entries = queue:peek_batch(10)
for _i, entry in ipairs(entries) do
    expect(entry.id ~= removed_id, "deleted entry no longer replays")
end

-- Age pruning: enqueue drops entries older than the retention window.
clock.value = clock.value + 8 * 86400
queue:enqueue("300", 30)
expect(queue:count() == 1, "aged entries are pruned on enqueue")

-- Row bound: enqueueing beyond max_rows evicts the oldest entries.
rows = {}
next_id = 1
local bounded = new_queue({ max_rows = 3, merge_window = 0 })
bounded:enqueue("a", 30)
bounded:enqueue("b", 30)
bounded:enqueue("c", 30)
bounded:enqueue("d", 30)
expect(bounded:count() == 3, "row bound is enforced")
local bounded_entries = bounded:peek_batch(10)
expect(bounded_entries[1].book_id == "b", "the oldest entry was evicted")

-- Attempt pruning: entries that failed too often are dropped on enqueue.
rows = {}
next_id = 1
local flaky = new_queue({ merge_window = 0 })
flaky:enqueue("x", 30)
local flaky_id = flaky:peek_batch(1)[1].id
for _i = 1, 5 do
    flaky:mark_failed(flaky_id, "boom")
end
flaky:enqueue("y", 30)
expect(flaky:count() == 1, "over-failed entries are pruned on enqueue")
expect(flaky:peek_batch(1)[1].book_id == "y", "the surviving entry is the fresh one")

-- Invalid input: empty book or zero time never touches the database.
rows = {}
next_id = 1
local invalid = new_queue()
expect(invalid:enqueue("", 30) == false, "empty book id is rejected")
expect(invalid:enqueue("1", 0) == false, "zero seconds is rejected")
expect(invalid:count() == 0, "invalid input enqueued nothing")

print("read_report_queue_spec passed (" .. checks .. " checks)")
