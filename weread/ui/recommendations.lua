-- Bookstore recommendation and similar-book browsing flows.
local logger = require("weread.lib.logger")
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error

local M = {}

local PAGE_SIZE = 20

local function book_item(self, book)
    local title = book.title or book.bookId or _("Untitled")
    return {
        text = title,
        post_text = book.author or "",
        mandatory = book.category or "",
        callback = self:safeCallback(title, function()
            self:showBookRecord(book)
        end),
    }
end

local function append_load_more(self, items, loadPage)
    items[#items + 1] = {
        text = _("Load more"),
        weread_load_more = true,
        callback = self:safeCallback(_("Load more"), loadPage),
    }
end

local function drop_load_more(items)
    if items[#items] and items[#items].weread_load_more then
        items[#items] = nil
    end
end

function M:showRecommendations()
    if not self:requireLogin(true, true) then
        return
    end
    local items = {}
    local max_idx
    local view
    local loadPage
    loadPage = function()
        self:runOnlineTask(_("Recommendations"), function()
            local ok, result = pcall(function()
                return self.client:get_recommendations(PAGE_SIZE, max_idx)
            end)
            if not ok then
                logger.err("recommendations failed:", log_error(result))
                self:showInfo(T(_("Recommendations failed:\n%1"), display_error(result)))
                return
            end
            if view then
                UIManager:close(view)
                view = nil
            end
            drop_load_more(items)
            local books = type(result) == "table" and result.books or {}
            if #books == 0 then
                if #items == 0 then
                    self:showInfo(_("No recommendations yet."))
                else
                    self:showList(_("For you"), items, _("No more recommendations."))
                end
                return
            end
            for _i, book in ipairs(books) do
                items[#items + 1] = book_item(self, book)
                local search_idx = tonumber(book.searchIdx)
                if search_idx then
                    max_idx = search_idx
                end
            end
            if #books >= PAGE_SIZE then
                append_load_more(self, items, loadPage)
            end
            view = self:showList(_("For you"), items, _("No recommendations yet."))
        end)
    end
    loadPage()
end

function M:showSimilarBooks(book)
    if not self:requireLogin(true, true) then
        return
    end
    local book_id = book and (book.book_id or book.bookId)
    if not book_id then
        return
    end
    local title = book.title or book_id
    local session_id
    local max_idx
    local items = {}
    local view
    local loadPage
    loadPage = function()
        self:runOnlineTask(_("Similar books"), function()
            local ok, result = pcall(function()
                return self.client:get_similar_books(book_id, PAGE_SIZE, max_idx, session_id)
            end)
            if not ok then
                logger.err("similar books failed:", log_error(result))
                self:showInfo(T(_("Similar books failed:\n%1"), display_error(result)))
                return
            end
            if view then
                UIManager:close(view)
                view = nil
            end
            drop_load_more(items)
            local similar = type(result) == "table" and result.booksimilar or {}
            session_id = similar.sessionId or session_id
            local entries = similar.books or {}
            if #entries == 0 then
                if #items == 0 then
                    self:showInfo(_("No similar books found."))
                else
                    self:showList(T(_("Similar to %1"), title), items, _("No more similar books."))
                end
                return
            end
            for _i, entry in ipairs(entries) do
                local info = entry and entry.book and entry.book.bookInfo
                if info then
                    items[#items + 1] = book_item(self, info)
                end
                local idx = tonumber(entry and entry.idx)
                if idx then
                    max_idx = idx
                end
            end
            if #entries >= PAGE_SIZE then
                append_load_more(self, items, loadPage)
            end
            view = self:showList(T(_("Similar to %1"), title), items, _("No similar books found."))
        end)
    end
    loadPage()
end

return M
