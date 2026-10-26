-- Focused tests for the offline read-report flow: offline ticks enqueue,
-- online triggers replay the queue through the report pipeline.

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            local noop = function() end
            return { dbg = noop, info = noop, warn = noop, err = noop }
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local function make_report(opts)
    opts = opts or {}
    local config = {
        enabled = opts.enabled ~= false,
        mode = "manual",
        book_id = opts.book_id or "100",
        book_title = "Book",
        interval_seconds = opts.interval or 30,
        offline_queue = opts.offline_queue,
    }
    local report = setmetatable({}, ReadReport)
    report.settings = {
        get = function(_self, key)
            if key == "read_report" then return config end
        end,
        is_cookie_configured = function() return opts.cookie_configured ~= false end,
        flush = function() end,
    }
    report.is_online = function() return opts.online ~= false end
    report.now = opts.now or function() return 2000 end
    report.position_provider = opts.position_provider
    report.scheduled = {}
    report.scheduler = {
        scheduleIn = function(_self, delay, fn)
            table.insert(report.scheduled, { delay = delay, fn = fn })
        end,
        unschedule = function() end,
    }
    report.get_document = function() return {} end
    report.detect_book = function() return opts.book_id or "100" end
    report.current_book_id = opts.book_id or "100"
    return report
end

local function make_queue(opts)
    opts = opts or {}
    local queue = {
        entries = opts.entries or {},
        enqueued = {},
        deleted = {},
        failed = {},
        unavailable = opts.unavailable,
    }
    function queue:available()
        return not self.unavailable
    end
    function queue:enqueue(book_id, rt, position)
        self.enqueued[#self.enqueued + 1] =
            { book_id = book_id, rt = rt, position = position }
    end
    function queue:count()
        return #self.entries
    end
    function queue:peek_batch(limit)
        local batch = {}
        for index = 1, math.min(limit, #self.entries) do
            batch[index] = self.entries[index]
        end
        return batch
    end
    function queue:delete(id)
        self.deleted[#self.deleted + 1] = id
        for index, entry in ipairs(self.entries) do
            if entry.id == id then table.remove(self.entries, index) break end
        end
    end
    function queue:mark_failed(id, _error)
        self.failed[#self.failed + 1] = id
    end
    return queue
end

-- An offline tick queues its reading time with the current position.
local offline = make_report({ online = false })
local offline_queue = make_queue()
offline.queue = offline_queue
offline.position_provider = function(_book_id)
    return { chapter_uid = 3, chapter_offset = 120, percent = 25 }, nil, true
end
local proceed = offline:_precheck()
expect(proceed == false, "offline tick does not proceed")
expect(#offline_queue.enqueued == 1, "offline tick enqueued its reading time")
expect(offline_queue.enqueued[1].rt == 30, "offline tick queues one interval")
expect(offline_queue.enqueued[1].position ~= nil
    and offline_queue.enqueued[1].position.chapter_offset == 120,
    "offline tick captures the position snapshot")

-- An offline tick without a verified position is dropped, not queued.
local stale = make_report({ online = false })
local stale_queue = make_queue()
stale.queue = stale_queue
stale.position_provider = function() return nil, "progress_unverified", true end
stale:_precheck()
expect(#stale_queue.enqueued == 0,
    "offline tick without a verified position is not queued")

-- The queue can be switched off, or unavailable without any enqueue.
local disabled = make_report({ online = false, offline_queue = false })
local disabled_queue = make_queue()
disabled.queue = disabled_queue
disabled.position_provider = function() return { chapter_uid = 1 }, nil, true end
disabled:_precheck()
expect(#disabled_queue.enqueued == 0, "disabled offline queue stays empty")
local degraded = make_report({ online = false })
local degraded_queue = make_queue({ unavailable = true })
degraded.queue = degraded_queue
degraded.position_provider = function() return { chapter_uid = 1 }, nil, true end
degraded:_precheck()
expect(#degraded_queue.enqueued == 0, "unavailable queue stays empty")

-- Flushing guards: no queue, no cookie, offline, empty queue, or busy.
local idle = make_report()
expect(idle:maybe_flush_queue("resume") == false, "flush is skipped without a queue")
local no_cookie = make_report({ cookie_configured = false })
no_cookie.queue = make_queue({ entries = { { id = 1, book_id = "100", rt = 30 } } })
expect(no_cookie:maybe_flush_queue("resume") == false, "flush is skipped without a cookie")
local is_offline = make_report({ online = false })
is_offline.queue = make_queue({ entries = { { id = 1, book_id = "100", rt = 30 } } })
expect(is_offline:maybe_flush_queue("resume") == false, "flush is skipped while offline")
local empty = make_report()
empty.queue = make_queue()
expect(empty:maybe_flush_queue("resume") == false, "flush is skipped with an empty queue")
local busy = make_report()
busy.queue = make_queue({ entries = { { id = 1, book_id = "100", rt = 30 } } })
busy.job = { pid = 42 }
expect(busy:maybe_flush_queue("resume") == false, "flush waits for an in-flight report job")

-- A pending batch is replayed through the pipeline, one entry per step.
local flushing = make_report()
local flush_queue = make_queue({
    entries = {
        { id = 1, book_id = "100", rt = 60, position = { chapter_uid = 2 } },
        { id = 2, book_id = "100", rt = 30, position = nil },
    },
})
flushing.queue = flush_queue
local pipeline_args = {}
function flushing:_run_pipeline(book_id, opts)
    pipeline_args[#pipeline_args + 1] = { book_id = book_id, opts = opts }
    return { accepted = true, book = nil }
end
expect(flushing:maybe_flush_queue("resume") == true, "flush starts with pending entries")
expect(flushing.flushing == true, "flush marks itself in progress")
expect(#flushing.scheduled == 1 and flushing.scheduled[1].delay == 0.1,
    "flush defers its first step off the UI loop")
-- The two entries replay one per scheduled step (pop each task as it runs,
-- the way UIManager does).
local step_count = 0
while #flushing.scheduled > 0 do
    local next_step = table.remove(flushing.scheduled, 1)
    step_count = step_count + 1
    next_step.fn()
end
expect(step_count >= 2, "each queued entry replays in its own step")
expect(#pipeline_args == 2, "both entries reached the pipeline")
expect(pipeline_args[1].opts.elapsed_seconds == 60
    and pipeline_args[2].opts.elapsed_seconds == 30,
    "each entry replays with its recorded seconds")
expect(pipeline_args[1].opts.position ~= nil
    and pipeline_args[1].opts.position.chapter_uid == 2,
    "the position snapshot is replayed")
expect(#flush_queue.deleted == 2 and #flush_queue.entries == 0,
    "accepted entries leave the queue")
expect(flushing.flushing == nil, "flush clears its in-progress flag")

-- Authentication failures stop the round and keep the remaining entries.
local auth_report = make_report()
local auth_queue = make_queue({
    entries = {
        { id = 1, book_id = "100", rt = 30 },
        { id = 2, book_id = "100", rt = 30 },
    },
})
auth_report.queue = auth_queue
function auth_report:_run_pipeline()
    return { accepted = false, error = "cookie renewal failed", error_kind = "authentication" }
end
auth_report:maybe_flush_queue("resume")
table.remove(auth_report.scheduled, 1).fn()
expect(#auth_queue.failed == 1 and #auth_queue.entries == 2,
    "an authentication failure stops the round and keeps the entries queued")
expect(auth_report.flushing == nil, "the stopped round releases the flush flag")

-- Success throttles opportunistic triggers but resume always fires.
local throttled = make_report()
throttled.queue = make_queue({ entries = { { id = 1, book_id = "100", rt = 30 } } })
throttled:_record_success({})
expect(#throttled.scheduled == 1,
    "the first success after offline time starts a flush")
-- The first round never ran; release its flag like the finished batch would.
throttled.flushing = nil
throttled.scheduled = {}
throttled:_record_success({})
expect(#throttled.scheduled == 0,
    "a second success inside the throttle window does not retrigger")
throttled.last_queue_flush = 1000
throttled.scheduled = {}
throttled:_record_success({})
expect(#throttled.scheduled == 1,
    "success outside the throttle window starts a flush again")

-- Resume (e.g. waking the device) attempts a flush.
local resumed = make_report({ enabled = false })
resumed.queue = make_queue({ entries = { { id = 1, book_id = "100", rt = 30 } } })
resumed:on_resume()
expect(#resumed.scheduled == 1, "resume triggers a flush attempt")

-- Manual drain: flush_all replays synchronously and reports the tally.
local manual = make_report()
local manual_queue = make_queue({
    entries = {
        { id = 1, book_id = "100", rt = 30 },
        { id = 2, book_id = "100", rt = 60 },
    },
})
manual.queue = manual_queue
function manual:_run_pipeline(book_id, opts)
    if opts.elapsed_seconds == 30 then
        return { accepted = true, book = nil }
    end
    return { accepted = false, error = "boom", error_kind = "server" }
    end
local sent, failed = manual:flush_all("manual")
expect(sent == 1 and failed == 1, "manual drain reports sent and failed counts")
expect(#manual_queue.entries == 1,
    "accepted entries are removed and failed ones stay queued")
expect(manual:pendingCount() == 1, "pendingCount reflects the queue")

print("read_report_offline_spec passed (" .. checks .. " checks)")
