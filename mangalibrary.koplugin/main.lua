--[[
    Manga Library Plugin for KOReader
    FINAL FIX - Seamless works for all chapters by always calling show() with callback
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local PathChooser = require("ui/widget/pathchooser")
local ReaderUI = require("apps/reader/readerui")
local Event = require("ui/event")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local GlobalState = {
    is_showing = false,
    current_series = nil,
    current_chapter_path = nil,
    manga_folders = {},
    reading_progress = {},
    seamless_enabled = false,
    debug_log = {},
}

local MangaLibrary = WidgetContainer:extend{
    name = "mangalibrary",
    is_doc_only = false,
}

local SUPPORTED_FORMATS = {
    cbz = true, cbr = true, cb7 = true,
    zip = true, rar = true, ["7z"] = true,
    pdf = true, epub = true,
}

function MangaLibrary:debugLog(msg)
    local timestamp = os.date("%H:%M:%S")
    table.insert(GlobalState.debug_log, timestamp .. " - " .. msg)
    logger.info("MangaLibrary: " .. msg)
    if #GlobalState.debug_log > 50 then
        table.remove(GlobalState.debug_log, 1)
    end
end

function MangaLibrary:init()
    self:loadSettings()
    if not self.ui then
        self:debugLog("No UI context")
        return
    end
    self:debugLog("Init from " .. (self.ui.name or "unknown"))
    self.ui.menu:registerToMainMenu(self)
    if self.ui.name == "ReaderUI" and GlobalState.seamless_enabled then
        self:debugLog("ReaderUI + seamless, hooking")
        self.ui:registerPostInitCallback(function()
            self:hookWithPriorityOntoReaderUiEvents(self.ui)
        end)
    end
    self:debugLog("Init complete")
end

function MangaLibrary:hookWithPriorityOntoReaderUiEvents(ui)
    if ui._ml_hooked then
        self:debugLog("Already hooked")
        return
    end
    self:debugLog("Hooking events")
    local eventListener = WidgetContainer:new({})
    local plugin = self
    eventListener.onEndOfBook = function()
        plugin:debugLog(">>> onEndOfBook <<<")
        return plugin:onEndOfBook()
    end
    eventListener.onCloseWidget = function()
        plugin:onReaderUiCloseWidget()
        ui._ml_hooked = nil
    end
    table.insert(ui, 2, eventListener)
    ui._ml_hooked = true
    self:debugLog("✓ Hooked at position 2")
end

function MangaLibrary:loadSettings()
    local path = DataStorage:getSettingsDir() .. "/mangalibrary.lua"
    pcall(function()
        local s = LuaSettings:open(path)
        GlobalState.manga_folders = s:readSetting("manga_folders") or {}
        GlobalState.reading_progress = s:readSetting("reading_progress") or {}
        GlobalState.seamless_enabled = s:readSetting("seamless_enabled") or false
    end)
end

function MangaLibrary:saveSettings()
    pcall(function()
        local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/mangalibrary.lua")
        s:saveSetting("manga_folders", GlobalState.manga_folders)
        s:saveSetting("reading_progress", GlobalState.reading_progress)
        s:saveSetting("seamless_enabled", GlobalState.seamless_enabled)
        s:flush()
    end)
end

function MangaLibrary:extractNumber(str)
    local num = str:match("(%d+%.?%d*)")
    return num and tonumber(num) or 0
end

function MangaLibrary:sortChapters(chapters)
    table.sort(chapters, function(a, b)
        local na = self:extractNumber(a.name)
        local nb = self:extractNumber(b.name)
        return na ~= nb and na < nb or a.name < b.name
    end)
    return chapters
end

function MangaLibrary:isSupportedFormat(filename)
    local ext = filename:match("%.([^%.]+)$")
    return ext and SUPPORTED_FORMATS[ext:lower()] or false
end

function MangaLibrary:scanFolder(path)
    self:debugLog("Scanning: " .. path)
    path = path:gsub("/$", "")
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "directory" then
        UIManager:show(InfoMessage:new{text = _("Cannot access folder:\n") .. path, timeout = 3})
        return 0
    end
    local count = 0
    pcall(function()
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local spath = path .. "/" .. entry
                local sattr = lfs.attributes(spath)
                if sattr and sattr.mode == "directory" then
                    local chapters = {}
                    pcall(function()
                        for file in lfs.dir(spath) do
                            if file ~= "." and file ~= ".." and self:isSupportedFormat(file) then
                                table.insert(chapters, {name = file, path = spath .. "/" .. file})
                            end
                        end
                    end)
                    if #chapters > 0 then
                        chapters = self:sortChapters(chapters)
                        if not GlobalState.reading_progress[entry] then
                            GlobalState.reading_progress[entry] = {chapters = chapters, read_chapters = {}}
                        else
                            GlobalState.reading_progress[entry].chapters = chapters
                        end
                        count = count + 1
                    end
                end
            end
        end
    end)
    self:debugLog("Found " .. count .. " series")
    return count
end

function MangaLibrary:refreshLibrary()
    UIManager:show(InfoMessage:new{text = _("Refreshing..."), timeout = 1})
    local old = GlobalState.reading_progress
    GlobalState.reading_progress = {}
    local total = 0
    for _, folder in ipairs(GlobalState.manga_folders) do
        total = total + self:scanFolder(folder)
    end
    for s, d in pairs(GlobalState.reading_progress) do
        if old[s] and old[s].read_chapters then
            d.read_chapters = old[s].read_chapters
        end
    end
    self:saveSettings()
    UIManager:show(InfoMessage:new{text = string.format(_("Found %d series"), total), timeout = 2})
end

function MangaLibrary:getSeriesStats(series_name)
    local d = GlobalState.reading_progress[series_name]
    if not d then return 0, 0 end
    local total = #d.chapters
    local read = 0
    for _ in pairs(d.read_chapters or {}) do read = read + 1 end
    return read, total
end

function MangaLibrary:markChapter(series_name, path, is_read)
    if not GlobalState.reading_progress[series_name] then return end
    if not GlobalState.reading_progress[series_name].read_chapters then
        GlobalState.reading_progress[series_name].read_chapters = {}
    end
    if is_read then
        GlobalState.reading_progress[series_name].read_chapters[path] = true
    else
        GlobalState.reading_progress[series_name].read_chapters[path] = nil
    end
    self:saveSettings()
end

function MangaLibrary:markAllChapters(series_name, is_read)
    local d = GlobalState.reading_progress[series_name]
    if not d then return end
    if not d.read_chapters then d.read_chapters = {} end
    for _, c in ipairs(d.chapters) do
        if is_read then
            d.read_chapters[c.path] = true
        else
            d.read_chapters[c.path] = nil
        end
    end
    self:saveSettings()
end

function MangaLibrary:getNextChapter(series_name, current_path)
    local d = GlobalState.reading_progress[series_name]
    if not d then return nil end
    for i, c in ipairs(d.chapters) do
        if c.path == current_path and i < #d.chapters then
            return d.chapters[i + 1]
        end
    end
    return nil
end

-- CRITICAL: Use show() like rakuyomi with callback
function MangaLibrary:show(options)
    self:debugLog("show() called with path: " .. options.path)
    GlobalState.current_series = options.series
    GlobalState.current_chapter_path = options.path
    
    if GlobalState.is_showing and ReaderUI.instance then
        self:debugLog("Using switchDocument")
        ReaderUI.instance:switchDocument(options.path)
    else
        self:debugLog("Using showReader")
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(options.path)
    end
    GlobalState.is_showing = true
end

function MangaLibrary:openChapter(series_name, chapter_path)
    self:debugLog("openChapter: " .. chapter_path)
    self:show({series = series_name, path = chapter_path})
end

function MangaLibrary:onEndOfBook()
    self:debugLog("onEndOfBook called, is_showing=" .. tostring(GlobalState.is_showing))
    if not GlobalState.is_showing then
        return false
    end
    if not (GlobalState.current_series and GlobalState.current_chapter_path) then
        return false
    end
    
    self:markChapter(GlobalState.current_series, GlobalState.current_chapter_path, true)
    local next = self:getNextChapter(GlobalState.current_series, GlobalState.current_chapter_path)
    
    if not next then
        self:debugLog("No next chapter")
        GlobalState.is_showing = false
        UIManager:show(InfoMessage:new{text = _("Series complete!"), timeout = 2})
        return true
    end
    
    self:debugLog("Switching to: " .. next.name)
    
    -- CRITICAL: Call show() again like rakuyomi does
    self:show({series = GlobalState.current_series, path = next.path})
    
    UIManager:show(InfoMessage:new{text = _("Next: ") .. next.name, timeout = 1})
    return true
end

function MangaLibrary:onReaderUiCloseWidget()
    self:debugLog("ReaderUI closed")
    GlobalState.is_showing = false
end

function MangaLibrary:showChapterList(series_name)
    local d = GlobalState.reading_progress[series_name]
    if not d then
        UIManager:show(InfoMessage:new{text = _("Series not found"), timeout = 2})
        return
    end
    local items = {}
    table.insert(items, {text = _("Mark All Read"), callback = function()
        self:markAllChapters(series_name, true)
        UIManager:close(self.chapter_menu)
        self:showChapterList(series_name)
    end})
    table.insert(items, {text = _("Mark All Unread"), callback = function()
        self:markAllChapters(series_name, false)
        UIManager:close(self.chapter_menu)
        self:showChapterList(series_name)
    end})
    table.insert(items, {text = " ", enabled = false})
    for _, c in ipairs(d.chapters) do
        local is_read = d.read_chapters and d.read_chapters[c.path]
        local icon = is_read and "✓ " or "○ "
        table.insert(items, {
            text = icon .. c.name,
            callback = function()
                UIManager:close(self.chapter_menu)
                self:openChapter(series_name, c.path)
            end,
            hold_callback = function()
                self:showChapterOptions(series_name, c.path, c.name)
            end,
        })
    end
    local read, total = self:getSeriesStats(series_name)
    self.chapter_menu = Menu:new{
        title = string.format("%s (%d/%d)", series_name, read, total),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "back",
        onLeftButtonTap = function()
            UIManager:close(self.chapter_menu)
            self:showLibrary()
        end,
        close_callback = function()
            UIManager:close(self.chapter_menu)
        end,
    }
    UIManager:show(self.chapter_menu)
end

function MangaLibrary:showChapterOptions(series_name, path, name)
    local d = GlobalState.reading_progress[series_name]
    local is_read = d.read_chapters and d.read_chapters[path]
    local buttons = {
        {{text = _("Open"), callback = function()
            UIManager:close(self.chapter_dialog)
            self:openChapter(series_name, path)
        end}},
        {{text = is_read and _("Mark Unread") or _("Mark Read"), callback = function()
            UIManager:close(self.chapter_dialog)
            self:markChapter(series_name, path, not is_read)
            self:showChapterList(series_name)
        end}},
        {{text = _("Cancel"), callback = function()
            UIManager:close(self.chapter_dialog)
        end}},
    }
    self.chapter_dialog = ButtonDialog:new{title = name, buttons = buttons}
    UIManager:show(self.chapter_dialog)
end

function MangaLibrary:showLibrary()
    local items = {}
    local list = {}
    for s in pairs(GlobalState.reading_progress) do
        table.insert(list, s)
    end
    table.sort(list)
    if #list == 0 then
        table.insert(items, {text = _("No manga found"), enabled = false})
        table.insert(items, {text = _("Add folders in Settings"), enabled = false})
        table.insert(items, {text = " ", enabled = false})
    else
        for _, s in ipairs(list) do
            local r, t = self:getSeriesStats(s)
            local st = r == t and "✓" or "○"
            table.insert(items, {
                text = string.format("%s %s (%d/%d)", st, s, r, t),
                callback = function()
                    UIManager:close(self.library_menu)
                    self:showChapterList(s)
                end,
            })
        end
    end
    self.library_menu = Menu:new{
        title = _("Manga Library"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self:showSettings()
        end,
        title_bar_right_icon = "exit",
        onRightButtonTap = function()
            UIManager:close(self.library_menu)
        end,
        close_callback = function()
            UIManager:close(self.library_menu)
        end,
    }
    UIManager:show(self.library_menu)
end

function MangaLibrary:showSettings()
    local buttons = {
        {{text = _("Manage Folders"), callback = function()
            UIManager:close(self.settings_dialog)
            self:showFolderManager()
        end}},
        {{text = _("Refresh Library"), callback = function()
            UIManager:close(self.settings_dialog)
            self:refreshLibrary()
        end}},
        {{text = GlobalState.seamless_enabled and _("Seamless: ON ✓") or _("Seamless: OFF"), callback = function()
            UIManager:close(self.settings_dialog)
            GlobalState.seamless_enabled = not GlobalState.seamless_enabled
            self:saveSettings()
            UIManager:show(InfoMessage:new{
                text = GlobalState.seamless_enabled and _("Seamless enabled\nReopen chapter") or _("Seamless disabled"),
                timeout = 2,
            })
        end}},
        {{text = _("View Debug Log"), callback = function()
            UIManager:close(self.settings_dialog)
            self:showDebugLog()
        end}},
        {{text = _("Diagnostics"), callback = function()
            UIManager:close(self.settings_dialog)
            self:showDiagnostics()
        end}},
        {{text = _("Close"), callback = function()
            UIManager:close(self.settings_dialog)
        end}},
    }
    self.settings_dialog = ButtonDialog:new{title = _("Settings"), buttons = buttons}
    UIManager:show(self.settings_dialog)
end

function MangaLibrary:showFolderManager()
    local items = {}
    for i, f in ipairs(GlobalState.manga_folders) do
        table.insert(items, {
            text = f,
            hold_callback = function()
                self:showFolderOptions(i, f)
            end,
        })
    end
    if #GlobalState.manga_folders > 0 then
        table.insert(items, {text = " ", enabled = false})
    end
    table.insert(items, {text = _("+ Add Folder"), callback = function()
        UIManager:close(self.folder_menu)
        self:addFolder()
    end})
    self.folder_menu = Menu:new{
        title = _("Folders"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "back",
        onLeftButtonTap = function()
            UIManager:close(self.folder_menu)
            self:showSettings()
        end,
        close_callback = function()
            UIManager:close(self.folder_menu)
        end,
    }
    UIManager:show(self.folder_menu)
end

function MangaLibrary:showFolderOptions(index, folder)
    local buttons = {
        {{text = _("Rescan"), callback = function()
            UIManager:close(self.folder_dialog)
            local c = self:scanFolder(folder)
            self:saveSettings()
            UIManager:show(InfoMessage:new{text = string.format(_("Found %d series"), c), timeout = 2})
        end}},
        {{text = _("Remove"), callback = function()
            UIManager:close(self.folder_dialog)
            table.remove(GlobalState.manga_folders, index)
            self:saveSettings()
            UIManager:show(InfoMessage:new{text = _("Removed"), timeout = 2})
            UIManager:scheduleIn(0.3, function()
                self:showFolderManager()
            end)
        end}},
        {{text = _("Cancel"), callback = function()
            UIManager:close(self.folder_dialog)
        end}},
    }
    self.folder_dialog = ButtonDialog:new{title = folder, buttons = buttons}
    UIManager:show(self.folder_dialog)
end

function MangaLibrary:addFolder()
    local chooser
    chooser = PathChooser:new{
        title = _("Select Manga Folder"),
        path = "/mnt/us/",
        select_directory = true,
        onConfirm = function(path)
            UIManager:close(chooser)
            for _, f in ipairs(GlobalState.manga_folders) do
                if f == path then
                    UIManager:show(InfoMessage:new{text = _("Already added"), timeout = 2})
                    UIManager:scheduleIn(0.3, function() self:showFolderManager() end)
                    return
                end
            end
            table.insert(GlobalState.manga_folders, path)
            local c = self:scanFolder(path)
            self:saveSettings()
            UIManager:show(InfoMessage:new{text = string.format(_("Added! Found %d series"), c), timeout = 2})
            UIManager:scheduleIn(0.3, function() self:showFolderManager() end)
        end,
        onCancel = function()
            UIManager:close(chooser)
            self:showFolderManager()
        end,
    }
    UIManager:show(chooser)
end

function MangaLibrary:showDebugLog()
    local txt = "=== Debug Log ===\n\n"
    local start = math.max(1, #GlobalState.debug_log - 29)
    for i = start, #GlobalState.debug_log do
        txt = txt .. GlobalState.debug_log[i] .. "\n"
    end
    if #GlobalState.debug_log == 0 then
        txt = txt .. "No entries"
    end
    UIManager:show(InfoMessage:new{text = txt, timeout = 20})
end

function MangaLibrary:showDiagnostics()
    local info = {"=== Diagnostics ===", "", "Folders: " .. #GlobalState.manga_folders}
    local sc, tc = 0, 0
    for _, d in pairs(GlobalState.reading_progress) do
        sc = sc + 1
        tc = tc + #d.chapters
    end
    table.insert(info, "Series: " .. sc)
    table.insert(info, "Chapters: " .. tc)
    table.insert(info, "")
    table.insert(info, "Seamless: " .. (GlobalState.seamless_enabled and "ON" or "OFF"))
    table.insert(info, "Is showing: " .. (GlobalState.is_showing and "YES" or "NO"))
    if GlobalState.current_series then
        table.insert(info, "Series: " .. GlobalState.current_series)
    end
    UIManager:show(InfoMessage:new{text = table.concat(info, "\n"), timeout = 10})
end

function MangaLibrary:addToMainMenu(menu_items)
    menu_items.mangalibrary = {
        text = _("Manga Library"),
        sorting_hint = "search",
        callback = function()
            self:showLibrary()
        end,
    }
end

return MangaLibrary
