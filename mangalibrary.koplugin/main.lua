local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local ReaderUI = require("apps/reader/readerui")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

-- SEAMLESS SWITCHING: Global state
local GlobalState = {
    is_showing = false,
    current_series = nil,
    current_chapter_path = nil,
    error_log = {},
}

local function debugLog(msg)
    local timestamp = os.date("%H:%M:%S")
    local log_entry = timestamp .. " - " .. tostring(msg)
    table.insert(GlobalState.error_log, log_entry)
    logger.info("MangaLibrary: " .. msg)
    if #GlobalState.error_log > 100 then
        table.remove(GlobalState.error_log, 1)
    end
end

local MangaLibrary = WidgetContainer:extend{
    name = "mangalibrary",
    is_doc_only = false,
}

local MangaLibraryWidget = InputContainer:extend{
    title = _("Manga Library"),
}

function MangaLibrary:init()
    debugLog("MangaLibrary:init() starting")
    
    self.settings_file = DataStorage:getSettingsDir() .. "/manga_library.lua"
    self.settings = LuaSettings:open(self.settings_file)
    self.manga_folders = self.settings:readSetting("manga_folders") or {}
    self.reading_progress = self.settings:readSetting("reading_progress") or {}
    
    debugLog("Registering to main menu")
    self.ui.menu:registerToMainMenu(self)
    
    -- SEAMLESS SWITCHING: Hook into ReaderUI
    if self.ui and self.ui.name == "ReaderUI" then
        debugLog("Init: Detected ReaderUI context")
        if self.ui.registerPostInitCallback then
            self.ui:registerPostInitCallback(function()
                debugLog("PostInit: Hooking into ReaderUI")
                self:hookWithPriorityOntoReaderUiEvents(self.ui)
            end)
        end
    else
        debugLog("Init: Not ReaderUI context")
    end
    
    debugLog("MangaLibrary:init() complete")
end

-- SEAMLESS SWITCHING: Hook function
function MangaLibrary:hookWithPriorityOntoReaderUiEvents(ui)
    if ui._ml_hooked then
        debugLog("Already hooked")
        return
    end
    
    debugLog("Hooking onto ReaderUI events")
    
    local eventListener = WidgetContainer:new({})
    local plugin = self
    
    eventListener.onEndOfBook = function()
        debugLog(">>> eventListener.onEndOfBook FIRED <<<")
        return plugin:onEndOfBook()
    end
    
    eventListener.onCloseWidget = function()
        plugin:onReaderUiCloseWidget()
        ui._ml_hooked = nil
    end
    
    table.insert(ui, 2, eventListener)
    ui._ml_hooked = true
    
    debugLog("✓✓✓ Event listener hooked at position 2 ✓✓✓")
end

-- SEAMLESS SWITCHING: show() method that can be called multiple times
function MangaLibrary:show(options)
    debugLog("show() called with path: " .. options.path)
    GlobalState.current_series = options.series
    GlobalState.current_chapter_path = options.path
    
    if GlobalState.is_showing and ReaderUI.instance then
        debugLog("Using switchDocument")
        ReaderUI.instance:switchDocument(options.path)
    else
        debugLog("Using showReader")
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(options.path)
    end
    GlobalState.is_showing = true
end

-- SEAMLESS SWITCHING: End of book handler that calls show() again
function MangaLibrary:onEndOfBook()
    debugLog(">>> onEndOfBook CALLED <<<")
    debugLog("is_showing: " .. tostring(GlobalState.is_showing))
    
    if not GlobalState.is_showing then
        debugLog("is_showing=false, not handling")
        return false
    end
    
    if not (GlobalState.current_series and GlobalState.current_chapter_path) then
        debugLog("No current series/chapter")
        return false
    end
    
    -- Mark current as read
    self:markChapter(GlobalState.current_series, GlobalState.current_chapter_path, true)
    
    -- Get next chapter
    local next_chapter = self:getNextChapter(GlobalState.current_series, GlobalState.current_chapter_path)
    
    if not next_chapter then
        debugLog("No next chapter")
        GlobalState.is_showing = false
        UIManager:show(InfoMessage:new{
            text = _("Series complete!"),
            timeout = 2,
        })
        return true
    end
    
    debugLog("Switching to: " .. next_chapter.name)
    
    -- CRITICAL: Call show() again to re-establish context for next chapter
    self:show({series = GlobalState.current_series, path = next_chapter.path})
    
    UIManager:show(InfoMessage:new{
        text = _("Next: ") .. next_chapter.name,
        timeout = 1,
    })
    
    debugLog(">>> RETURNING TRUE <<<")
    return true
end

function MangaLibrary:getNextChapter(series_name, current_path)
    local series_data = self.reading_progress[series_name]
    if not series_data or not series_data.chapters then 
        debugLog("getNextChapter: No series data")
        return nil 
    end
    
    for i, chapter in ipairs(series_data.chapters) do
        if chapter.path == current_path and i < #series_data.chapters then
            debugLog("getNextChapter: Found next at index " .. (i + 1))
            return series_data.chapters[i + 1]
        end
    end
    
    debugLog("getNextChapter: No next chapter found")
    return nil
end

function MangaLibrary:onReaderUiCloseWidget()
    debugLog("ReaderUI closing, resetting is_showing")
    GlobalState.is_showing = false
end

function MangaLibrary:markChapter(series_name, chapter_path, is_read)
    if not self.reading_progress[series_name] then return end
    if not self.reading_progress[series_name].read_chapters then
        self.reading_progress[series_name].read_chapters = {}
    end
    
    if is_read then
        self.reading_progress[series_name].read_chapters[chapter_path] = true
    else
        self.reading_progress[series_name].read_chapters[chapter_path] = nil
    end
    self.settings:saveSetting("reading_progress", self.reading_progress)
    self.settings:flush()
end

function MangaLibrary:addToMainMenu(menu_items)
    menu_items.manga_library = {
        text = _("Manga Library"),
        sorting_hint = "tools",
        callback = function()
            self:showMangaLibraryFullScreen()
        end,
    }
end

function MangaLibrary:showMangaLibraryFullScreen()
    local manga_widget = MangaLibraryWidget:new{
        manga_library = self,
        dimen = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight()
        }
    }
    UIManager:show(manga_widget)
end

function MangaLibraryWidget:init()
    self.manga_library = self.manga_library or {}
    self.current_view = "library"
    self.current_series = nil
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self:buildLibraryView()
    
    self.key_events = {
        Close = { { "Back" }, doc = "close manga library" },
    }
    
    debugLog("MangaLibraryWidget initialized")
end

function MangaLibraryWidget:buildLibraryView()
    self.current_view = "library"
    
    local title_bar = TitleBar:new{
        width = self.width,
        align = "center",
        title = _("Manga Library"),
        title_face = Font:getFace("x_smalltfont"),
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            self:showSettings()
        end,
    }
    
    local manga_list = self:getMangaList()
    local content
    
    if #manga_list == 0 then
        local empty_text = TextWidget:new{
            text = _("No manga series found.\n\nUse the settings menu (⚙️) to add folders."),
            face = Font:getFace("infofont"),
            width = self.width - Size.padding.large * 2,
        }
        content = CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = self.height - title_bar:getHeight(),
            },
            empty_text,
        }
    else
        content = Menu:new{
            item_table = manga_list,
            is_borderless = true,
            is_popout = false,
            width = self.width,
            height = self.height - title_bar:getHeight(),
            close_callback = function() end,
        }
    end
    
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        VerticalGroup:new{
            align = "left",
            title_bar,
            content,
        }
    }
end

function MangaLibraryWidget:getMangaList()
    local manga_list = {}
    
    for series_name, series_data in pairs(self.manga_library.reading_progress) do
        if series_data.chapters and #series_data.chapters > 0 then
            local total_chapters = #series_data.chapters
            local read_chapters = 0
            
            for _, chapter in ipairs(series_data.chapters) do
                if series_data.read_chapters and series_data.read_chapters[chapter.path] then
                    read_chapters = read_chapters + 1
                end
            end
            
            local progress_text = "(" .. read_chapters .. "/" .. total_chapters .. ")"
            local status_icon = (read_chapters == total_chapters) and "[X] " or "[ ] "
            
            table.insert(manga_list, {
                text = status_icon .. series_name .. " " .. progress_text,
                series_name = series_name,
                callback = function()
                    self:showChapterView(series_name)
                end
            })
        end
    end
    
    table.insert(manga_list, {
        text = _("Close"),
        callback = function()
            UIManager:close(self)
        end
    })
    
    return manga_list
end

function MangaLibraryWidget:showSettings()
    local folder_count = #self.manga_library.manga_folders
    local folder_text = folder_count > 0 and
        _("Manage Folders") .. " (" .. folder_count .. ")" or
        _("Manage Folders")
    
    local buttons = {
        {{
            text = folder_text,
            callback = function()
                UIManager:close(self.settings_dialog)
                self:showFolderManagement()
            end,
        }},
        {{
            text = _("Refresh Library"),
            callback = function()
                UIManager:close(self.settings_dialog)
                self:refreshLibrary()
            end,
        }},
        {{
            text = _("View Error Log"),
            callback = function()
                UIManager:close(self.settings_dialog)
                self:showErrorLog()
            end,
        }},
        {{
            text = _("Close"),
            callback = function()
                UIManager:close(self.settings_dialog)
            end,
        }},
    }
    
    self.settings_dialog = ButtonDialog:new{
        title = _("Manga Library Settings"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.settings_dialog)
end

function MangaLibraryWidget:showErrorLog()
    local log_text = "=== MANGA LIBRARY ERROR LOG ===\n\n"
    
    if #GlobalState.error_log == 0 then
        log_text = log_text .. _("No errors logged yet.")
    else
        local start_idx = math.max(1, #GlobalState.error_log - 50)
        for i = start_idx, #GlobalState.error_log do
            log_text = log_text .. GlobalState.error_log[i] .. "\n"
        end
    end
    
    UIManager:show(InfoMessage:new{
        text = log_text,
        timeout = 30,
    })
end

function MangaLibraryWidget:showFolderManagement()
    local folder_list = {}
    
    table.insert(folder_list, {
        text = "+ " .. _("Add New Folder"),
        callback = function()
            if self.folder_management_menu then
                UIManager:close(self.folder_management_menu)
            end
            self:showFolderBrowser()
        end
    })
    
    if #self.manga_library.manga_folders > 0 then
        table.insert(folder_list, {
            text = "",
            callback = function() end
        })
        
        for i, folder_path in ipairs(self.manga_library.manga_folders) do
            local display_path = folder_path
            if #display_path > 40 then
                display_path = "..." .. display_path:sub(-37)
            end
            
            table.insert(folder_list, {
                text = display_path,
                hold_callback = function()
                    self:showFolderOptions(folder_path, i)
                end,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Long press to manage this folder\n\n") .. folder_path,
                        timeout = 2,
                    })
                end
            })
        end
    else
        table.insert(folder_list, {
            text = "",
            callback = function() end
        })
        table.insert(folder_list, {
            text = _("No folders added yet"),
            callback = function() end
        })
    end
    
    table.insert(folder_list, {
        text = "",
        callback = function() end
    })
    table.insert(folder_list, {
        text = "< " .. _("Back"),
        callback = function()
            if self.folder_management_menu then
                UIManager:close(self.folder_management_menu)
            end
            self:showSettings()
        end
    })
    
    self.folder_management_menu = Menu:new{
        title = _("Manage Manga Folders"),
        item_table = folder_list,
        is_borderless = true,
        is_popout = false,
        show_parent = self,
        width = self.width,
        height = self.height,
        close_callback = function()
            UIManager:close(self.folder_management_menu)
            self.folder_management_menu = nil
        end,
    }
    UIManager:show(self.folder_management_menu)
end

function MangaLibraryWidget:showFolderOptions(folder_path, folder_index)
    local folder_name = folder_path:match("([^/]+)/?$") or folder_path
    if #folder_name > 20 then
        folder_name = folder_name:sub(1, 17) .. "..."
    end
    
    local buttons = {
        {{
            text = _("Remove Folder"),
            callback = function()
                if self.folder_options_dialog then
                    UIManager:close(self.folder_options_dialog)
                    self.folder_options_dialog = nil
                end
                self:confirmRemoveFolder(folder_path, folder_index)
            end,
        }},
        {{
            text = _("Rescan Folder"),
            callback = function()
                if self.folder_options_dialog then
                    UIManager:close(self.folder_options_dialog)
                    self.folder_options_dialog = nil
                end
                self:rescanFolder(folder_path)
            end,
        },
        {
            text = _("Cancel"),
            callback = function()
                if self.folder_options_dialog then
                    UIManager:close(self.folder_options_dialog)
                    self.folder_options_dialog = nil
                end
            end,
        }},
    }
    
    self.folder_options_dialog = ButtonDialog:new{
        title = folder_name,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.folder_options_dialog)
end

function MangaLibraryWidget:showFolderBrowser()
    local start_path = "/mnt/us/"
    local possible_paths = {
        "/mnt/us/",
        "/mnt/onboard/",
        "/mnt/sd/",
        "/storage/emulated/0/",
    }
    
    for _, path in ipairs(possible_paths) do
        if lfs.attributes(path) then
            start_path = path
            break
        end
    end
    
    self.folder_chooser = PathChooser:new{
        title = _("Select Manga Folder"),
        path = start_path,
        select_directory = true,
        select_file = false,
        show_files = false,
        width = self.width,
        height = self.height,
        onConfirm = function(folder_path)
            if self.folder_chooser then
                UIManager:close(self.folder_chooser)
                self.folder_chooser = nil
            end
            self:confirmAddFolder(folder_path)
        end,
        onCancel = function()
            if self.folder_chooser then
                UIManager:close(self.folder_chooser)
                self.folder_chooser = nil
            end
            self:showFolderManagement()
        end,
    }
    UIManager:show(self.folder_chooser)
end

function MangaLibraryWidget:confirmAddFolder(folder_path)
    if self.manga_library:folderExists(folder_path) then
        UIManager:show(InfoMessage:new{
            text = _("This folder is already in your library."),
            timeout = 2,
        })
        UIManager:scheduleIn(0.5, function()
            self:showFolderManagement()
        end)
        return
    end
    
    local series_count = self:previewFolderContent(folder_path)
    local preview_text = series_count > 0 and
        _("Found ") .. series_count .. _(" manga series.") or
        _("No manga series found.")
    
    UIManager:show(ConfirmBox:new{
        title = _("Add Manga Folder?"),
        text = folder_path .. "\n\n" .. preview_text,
        ok_text = _("Add Folder"),
        ok_callback = function()
            self.manga_library:processFolder(folder_path)
            UIManager:show(InfoMessage:new{
                text = _("Folder added successfully!"),
                timeout = 2,
            })
            UIManager:scheduleIn(0.3, function()
                self:showFolderManagement()
            end)
        end,
        cancel_callback = function()
            self:showFolderManagement()
        end,
    })
end

function MangaLibraryWidget:previewFolderContent(folder_path)
    local series_count = 0
    local success, err = pcall(function()
        if folder_path:sub(-1) ~= "/" then
            folder_path = folder_path .. "/"
        end
        
        for item in lfs.dir(folder_path) do
            if item ~= "." and item ~= ".." then
                local item_path = folder_path .. item
                local item_attributes = lfs.attributes(item_path)
                
                if item_attributes and item_attributes.mode == "directory" then
                    local has_manga = false
                    for file in lfs.dir(item_path) do
                        if file ~= "." and file ~= ".." then
                            local ext = file:match("%.([^%.]+)$")
                            if ext and (ext:lower() == "cbz" or ext:lower() == "cbr" or
                                        ext:lower() == "cb7" or ext:lower() == "zip" or
                                        ext:lower() == "rar") then
                                has_manga = true
                                break
                            end
                        end
                    end
                    if has_manga then
                        series_count = series_count + 1
                    end
                end
            end
        end
    end)
    
    return success and series_count or 0
end

function MangaLibraryWidget:confirmRemoveFolder(folder_path, folder_index)
    UIManager:show(ConfirmBox:new{
        title = _("Remove Folder?"),
        text = folder_path .. "\n\n" .. _("Files will not be deleted"),
        ok_text = _("Remove"),
        ok_callback = function()
            table.remove(self.manga_library.manga_folders, folder_index)
            self.manga_library.settings:saveSetting("manga_folders", self.manga_library.manga_folders)
            self.manga_library.settings:flush()
            UIManager:show(InfoMessage:new{
                text = _("Folder removed from library."),
                timeout = 2,
            })
            UIManager:scheduleIn(0.3, function()
                self:showFolderManagement()
            end)
        end,
        cancel_callback = function()
            self:showFolderManagement()
        end,
    })
end

function MangaLibraryWidget:rescanFolder(folder_path)
    UIManager:show(InfoMessage:new{
        text = _("Rescanning folder..."),
        timeout = 1,
    })
    
    UIManager:scheduleIn(0.2, function()
        local success, err = pcall(function()
            self.manga_library:processFolderOnly(folder_path)
        end)
        
        local message = success and
            _("Folder rescanned successfully!") or
            _("Error rescanning folder")
        
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 2,
        })
        
        UIManager:scheduleIn(0.3, function()
            self:showFolderManagement()
        end)
    end)
end

function MangaLibraryWidget:showChapterView(series_name)
    self.current_view = "chapters"
    self.current_series = series_name
    
    debugLog("Showing chapter view for: " .. series_name)
    
    local series_data = self.manga_library.reading_progress[series_name]
    if not series_data or not series_data.chapters then
        UIManager:show(InfoMessage:new{
            text = _("No chapters found for this series."),
        })
        return
    end
    
    local title_bar = TitleBar:new{
        width = self.width,
        align = "center",
        title = series_name,
        title_face = Font:getFace("x_smalltfont"),
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            self:showSettings()
        end,
    }
    
    local chapter_list = {}
    
    table.insert(chapter_list, {
        text = "< " .. _("Back to Library"),
        callback = function()
            self:buildLibraryView()
            UIManager:setDirty(self, "ui")
        end
    })
    
    table.insert(chapter_list, {
        text = _("Mark All Read"),
        callback = function()
            self:markSeriesAsRead(series_name)
        end
    })
    
    table.insert(chapter_list, {
        text = _("Mark All Unread"),
        callback = function()
            self:markSeriesAsUnread(series_name)
        end
    })
    
    table.insert(chapter_list, {
        text = "",
        callback = function() end
    })
    
    for i, chapter in ipairs(series_data.chapters) do
        local is_read = series_data.read_chapters and series_data.read_chapters[chapter.path]
        local status_icon = is_read and "[X] " or "[ ] "
        
        table.insert(chapter_list, {
            text = status_icon .. chapter.name,
            callback = function()
                self:openChapter(chapter, series_name, i)
            end,
            hold_callback = function()
                self:showChapterOptions(chapter, series_name)
            end
        })
    end
    
    local content = Menu:new{
        item_table = chapter_list,
        is_borderless = true,
        is_popout = false,
        width = self.width,
        height = self.height - title_bar:getHeight(),
        close_callback = function()
            self:buildLibraryView()
            UIManager:setDirty(self, "ui")
        end,
    }
    
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        VerticalGroup:new{
            align = "left",
            title_bar,
            content,
        }
    }
    
    UIManager:setDirty(self, "ui")
end

function MangaLibraryWidget:markSeriesAsRead(series_name)
    UIManager:show(ConfirmBox:new{
        text = _("Mark all chapters as read?"),
        ok_text = _("Mark All Read"),
        ok_callback = function()
            local series_data = self.manga_library.reading_progress[series_name]
            if not series_data.read_chapters then
                series_data.read_chapters = {}
            end
            
            for _, chapter in ipairs(series_data.chapters or {}) do
                series_data.read_chapters[chapter.path] = true
            end
            
            self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
            self.manga_library.settings:flush()
            
            UIManager:show(InfoMessage:new{
                text = _("All chapters marked as read!"),
                timeout = 1,
            })
            
            UIManager:scheduleIn(0.2, function()
                self:showChapterView(series_name)
            end)
        end,
    })
end

function MangaLibraryWidget:markSeriesAsUnread(series_name)
    UIManager:show(ConfirmBox:new{
        text = _("Mark all chapters as unread?"),
        ok_text = _("Mark All Unread"),
        ok_callback = function()
            self.manga_library.reading_progress[series_name].read_chapters = {}
            self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
            self.manga_library.settings:flush()
            
            UIManager:show(InfoMessage:new{
                text = _("All chapters marked as unread!"),
                timeout = 1,
            })
            
            UIManager:scheduleIn(0.2, function()
                self:showChapterView(series_name)
            end)
        end,
    })
end

function MangaLibraryWidget:refreshLibrary()
    self.manga_library:refreshLibrary()
    
    if self.current_view == "library" then
        self:buildLibraryView()
    elseif self.current_view == "chapters" and self.current_series then
        self:showChapterView(self.current_series)
    end
    
    UIManager:setDirty(self, "ui")
end

function MangaLibraryWidget:showChapterOptions(chapter, series_name)
    local is_read = self.manga_library.reading_progress[series_name].read_chapters and
                    self.manga_library.reading_progress[series_name].read_chapters[chapter.path]
    
    local buttons = {
        {{
            text = is_read and _("Mark as Unread") or _("Mark as Read"),
            callback = function()
                UIManager:close(self.chapter_options_dialog)
                self:toggleChapterReadStatus(chapter, series_name)
            end,
        }},
        {{
            text = _("Open Chapter"),
            callback = function()
                UIManager:close(self.chapter_options_dialog)
                self:openChapter(chapter, series_name)
            end,
        }},
    }
    
    self.chapter_options_dialog = ButtonDialog:new{
        title = chapter.name,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.chapter_options_dialog)
end

function MangaLibraryWidget:toggleChapterReadStatus(chapter, series_name)
    if not self.manga_library.reading_progress[series_name].read_chapters then
        self.manga_library.reading_progress[series_name].read_chapters = {}
    end
    
    local current_status = self.manga_library.reading_progress[series_name].read_chapters[chapter.path]
    self.manga_library.reading_progress[series_name].read_chapters[chapter.path] = not current_status
    
    self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
    self.manga_library.settings:flush()
    
    local status_text = current_status and _("marked as unread") or _("marked as read")
    UIManager:show(InfoMessage:new{
        text = chapter.name .. " " .. status_text,
        timeout = 1,
    })
    
    UIManager:scheduleIn(0.2, function()
        self:showChapterView(series_name)
    end)
end

-- SEAMLESS SWITCHING: Open chapter using show() method
function MangaLibraryWidget:openChapter(chapter, series_name, chapter_index)
    debugLog("Opening: " .. chapter.path)
    debugLog("Series: " .. series_name)
    
    -- Mark as read
    if not self.manga_library.reading_progress[series_name].read_chapters then
        self.manga_library.reading_progress[series_name].read_chapters = {}
    end
    
    self.manga_library.reading_progress[series_name].read_chapters[chapter.path] = true
    self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
    self.manga_library.settings:flush()
    
    -- Close widget
    UIManager:close(self)
    
    -- CRITICAL: Use show() method
    self.manga_library:show({series = series_name, path = chapter.path})
    
    -- Hook after opening
    UIManager:scheduleIn(0.5, function()
        if ReaderUI.instance then
            debugLog("Hooking to ReaderUI after opening")
            self.manga_library:hookWithPriorityOntoReaderUiEvents(ReaderUI.instance)
        end
    end)
end

function MangaLibraryWidget:onClose()
    return true
end

function MangaLibraryWidget:onKeyClose()
    if self.current_view == "chapters" then
        self:buildLibraryView()
        UIManager:setDirty(self, "ui")
        return true
    else
        UIManager:close(self)
        return true
    end
end

function MangaLibrary:processFolder(folder_path)
    if folder_path:sub(-1) ~= "/" then
        folder_path = folder_path .. "/"
    end
    
    local attributes = lfs.attributes(folder_path)
    if not attributes or attributes.mode ~= "directory" then
        UIManager:show(InfoMessage:new{
            text = _("Folder does not exist: ") .. folder_path,
        })
        return
    end
    
    for item in lfs.dir(folder_path) do
        if item ~= "." and item ~= ".." then
            local item_path = folder_path .. item
            local item_attributes = lfs.attributes(item_path)
            
            if item_attributes and item_attributes.mode == "directory" then
                self:processMangaSeries(item_path, item)
            end
        end
    end
    
    if not self:folderExists(folder_path) then
        table.insert(self.manga_folders, folder_path)
        self.settings:saveSetting("manga_folders", self.manga_folders)
        self.settings:flush()
    end
end

function MangaLibrary:processFolderOnly(folder_path)
    if folder_path:sub(-1) ~= "/" then
        folder_path = folder_path .. "/"
    end
    
    for item in lfs.dir(folder_path) do
        if item ~= "." and item ~= ".." then
            local item_path = folder_path .. item
            local item_attributes = lfs.attributes(item_path)
            
            if item_attributes and item_attributes.mode == "directory" then
                self:processMangaSeries(item_path, item)
            end
        end
    end
    
    self.settings:saveSetting("reading_progress", self.reading_progress)
    self.settings:flush()
end

function MangaLibrary:folderExists(folder_path)
    for _, existing_path in ipairs(self.manga_folders) do
        if existing_path == folder_path then
            return true
        end
    end
    return false
end

function MangaLibrary:processMangaSeries(series_path, series_name)
    if series_path:sub(-1) ~= "/" then
        series_path = series_path .. "/"
    end
    
    local chapters = {}
    
    for item in lfs.dir(series_path) do
        if item ~= "." and item ~= ".." then
            local item_path = series_path .. item
            local item_attributes = lfs.attributes(item_path)
            
            if item_attributes and item_attributes.mode == "file" then
                local ext = item:match("%.([^%.]+)$")
                if ext and (ext:lower() == "cbz" or ext:lower() == "cbr" or
                            ext:lower() == "cb7" or ext:lower() == "zip" or
                            ext:lower() == "rar") then
                    table.insert(chapters, {
                        path = item_path,
                        name = item,
                        series = series_name
                    })
                end
            end
        end
    end
    
    table.sort(chapters, function(a, b)
        local a_num = tonumber(a.name:match("(%d+)")) or 0
        local b_num = tonumber(b.name:match("(%d+)")) or 0
        return a_num < b_num
    end)
    
    if not self.reading_progress[series_name] then
        self.reading_progress[series_name] = {}
    end
    
    self.reading_progress[series_name].chapters = chapters
    self.settings:saveSetting("reading_progress", self.reading_progress)
    self.settings:flush()
end

function MangaLibrary:refreshLibrary()
    local processed_count = 0
    
    for _, folder_path in ipairs(self.manga_folders) do
        local success, err = pcall(function()
            for item in lfs.dir(folder_path) do
                if item ~= "." and item ~= ".." then
                    local item_path = folder_path .. item
                    local item_attributes = lfs.attributes(item_path)
                    
                    if item_attributes and item_attributes.mode == "directory" then
                        self:processMangaSeries(item_path, item)
                        processed_count = processed_count + 1
                    end
                end
            end
        end)
        
        if not success then
            debugLog("Error processing folder: " .. folder_path .. " - " .. tostring(err))
        end
    end
    
    UIManager:show(InfoMessage:new{
        text = _("Library refreshed! Processed ") .. processed_count .. _(" series."),
    })
end

return MangaLibrary
