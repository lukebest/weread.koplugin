-- Focused tests for bookstore recommendation and similar-book flows.

package.path = "./?.lua;" .. package.path

local shown = {}
local closed = {}
package.preload["ui/bidi"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, opts) return opts end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_self, opts) return opts end }
end
package.preload["ui/widget/menu"] = function()
    return { new = function(_self, opts) return opts end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function(_self, widget) closed[#closed + 1] = widget end,
        scheduleIn = function() end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    local function template(text, ...)
        local args, n = { ... }, select("#", ...)
        for index = 1, n do
            args[index] = tostring(args[index])
        end
        return (text:gsub("%%(%d)", function(pos)
            pos = tonumber(pos)
            if pos and pos >= 1 and pos <= n then return args[pos] end
            return "%" .. pos
        end))
    end
    return {
        tr = function(text) return text end,
        T = template,
        log_error = tostring,
        display_error = function(err)
            return tostring(err):match("^[^\r\n]+") or tostring(err)
        end,
        unpack_args = unpack or table.unpack,
    }
end

local Mixin = require("weread.lib.mixin")
local Common = require("weread.ui.common")
local Recommendations = require("weread.ui.recommendations")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

local function newHost(client)
    local host = {}
    Mixin.apply(host, { Common, Recommendations })
    host.client = client
    function host:requireLogin() return true end
    -- Specs exercise the flows synchronously.
    function host:runOnlineTask(_label, callback) return callback() ~= nil and true or true end
    return host
end

local function infoTexts()
    local texts = {}
    for _i, widget in ipairs(shown) do
        if widget.text then texts[#texts + 1] = widget.text end
    end
    return texts
end

local function lastList()
    for index = #shown, 1, -1 do
        local widget = shown[index]
        if widget.item_table then return widget end
    end
    return nil
end

-- Recommendations: first page renders one item per book and opens the record.
local recommend_pages = {
    {
        books = {
            { bookId = "100", title = "Alpha", author = "Ann", category = "Fiction", searchIdx = 11 },
            { bookId = "200", title = "Beta", author = "Bob", category = "History", searchIdx = 12 },
        },
    },
}
local recommend_calls = {}
local opened_books = {}
local host = newHost({
    get_recommendations = function(_self, count, max_idx)
        recommend_calls[#recommend_calls + 1] = { count = count, max_idx = max_idx }
        local page = recommend_pages[#recommend_calls] or {}
        if page.error then error(page.error) end
        return { books = page.books or {} }
    end,
})
host.showBookRecord = function(_self, book) opened_books[#opened_books + 1] = book end
host:showRecommendations()
local list = lastList()
expect(list and list.title == "For you", "recommendations list is titled For you")
expect(list and #list.item_table == 2, "recommendations list has one item per book")
expect(list and list.item_table[1].text == "Alpha"
    and list.item_table[1].post_text == "Ann"
    and list.item_table[1].mandatory == "Fiction",
    "recommendation items carry title, author, and category")
list.item_table[1].callback()
expect(opened_books[1] and opened_books[1].bookId == "100",
    "tapping a recommendation opens its book record")
expect(#closed == 0, "first page does not close any previous list")

-- Recommendations: full pages append a load-more entry that pages by searchIdx.
local full_page = {}
for index = 1, 20 do
    full_page[index] = { bookId = tostring(index), title = "B" .. index, searchIdx = index }
end
local tail_page = {
    books = {
        { bookId = "901", title = "Tail", searchIdx = 901 },
        { bookId = "902", title = "Tail 2", searchIdx = 902 },
    },
}
local paged_calls = {}
local paged_client = {
    get_recommendations = function(_self, count, max_idx)
        paged_calls[#paged_calls + 1] = { count = count, max_idx = max_idx }
        if #paged_calls == 1 then return { books = full_page } end
        return { books = tail_page.books }
    end,
}
shown = {}
closed = {}
local paged_host = newHost(paged_client)
paged_host.showBookRecord = function() end
paged_host:showRecommendations()
list = lastList()
expect(list and #list.item_table == 21 and list.item_table[21].weread_load_more,
    "a full page appends a load-more entry")
expect(paged_calls[1].max_idx == nil, "the first page starts without max_idx")
list.item_table[21].callback()
list = lastList()
expect(paged_calls[2].max_idx == 20, "load-more pages from the last searchIdx")
expect(#list.item_table == 22 and list.item_table[21].text == "Tail"
    and list.item_table[22].text == "Tail 2",
    "the next page replaces the load-more entry with its books")
expect(#closed == 1, "loading the next page closes the previous list")

-- Recommendations: exhausted pages keep the earlier items.
local exhausted_calls = 0
local exhausted_client = {
    get_recommendations = function()
        exhausted_calls = exhausted_calls + 1
        if exhausted_calls == 1 then return { books = full_page } end
        return { books = {} }
    end,
}
shown = {}
closed = {}
local exhausted_host = newHost(exhausted_client)
exhausted_host.showBookRecord = function() end
exhausted_host:showRecommendations()
lastList().item_table[21].callback()
list = lastList()
expect(list and #list.item_table == 20 and not list.item_table[20].weread_load_more,
    "an exhausted page drops the load-more entry and keeps earlier items")

-- Recommendations: errors surface as info messages instead of crashing.
shown = {}
local error_host = newHost({
    get_recommendations = function() error("gateway down") end,
})
error_host:showRecommendations()
expect(#infoTexts() > 0 and infoTexts()[1]:find("Recommendations failed", 1, true) ~= nil,
    "a failed recommendations request reports the error")

-- Similar books: entries unwrap books[].book.bookInfo and reuse the session id.
local similar_pages = {
    { booksimilar = { sessionId = "s1", books = {
        { idx = 1, book = { bookInfo = { bookId = "300", title = "Gamma", author = "Gil" } } },
        { idx = 2, book = { bookInfo = { bookId = "400", title = "Delta" } } },
    } } },
    { booksimilar = { sessionId = "s1", books = {
        { idx = 3, book = { bookInfo = { bookId = "500", title = "Epsilon" } } },
    } } },
}
local similar_calls = {}
shown = {}
closed = {}
local similar_host = newHost({
    get_similar_books = function(_self, book_id, count, max_idx, session_id)
        similar_calls[#similar_calls + 1] =
            { book_id = book_id, count = count, max_idx = max_idx, session_id = session_id }
        return similar_pages[#similar_calls]
    end,
})
local similar_opened = {}
similar_host.showBookRecord = function(_self, book) similar_opened[#similar_opened + 1] = book end
similar_host:showSimilarBooks({ bookId = "100", title = "Alpha" })
list = lastList()
expect(list and list.title == "Similar to Alpha", "similar list is titled after the book")
expect(list and #list.item_table == 2 and list.item_table[1].text == "Gamma",
    "similar entries unwrap book.bookInfo")
list.item_table[2].callback()
expect(similar_opened[1] and similar_opened[1].bookId == "400",
    "tapping a similar book opens its record")

-- Similar books: empty result reports without a list.
shown = {}
local empty_similar_host = newHost({
    get_similar_books = function() return { booksimilar = { books = {} } } end,
})
empty_similar_host:showSimilarBooks({ bookId = "100" })
expect(#infoTexts() > 0 and infoTexts()[1] == "No similar books found.",
    "an empty similar result reports no books")

print("recommendations_spec passed (" .. checks .. " checks)")
