local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
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

local MangaLibrary = WidgetContainer:extend{
    name = "mangalibrary",
    is_doc_only = false,
}

local MangaLibraryWidget = InputContainer:extend{
    title = _("Manga Library"),
}

function MangaLibrary:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/manga_library.lua"
    self.settings = LuaSettings:open(self.settings_file)
    
    self.manga_folders = self.settings:readSetting("manga_folders") or {}
    self.reading_progress = self.settings:readSetting("reading_progress") or {}
    
    self.ui.menu:registerToMainMenu(self)
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
    
    -- Set dimensions
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    
    -- Create and show initial view
    self:buildLibraryView()
    
    -- Key events
    self.key_events = {
        Close = { { "Back" }, doc = "close manga library" },
    }
end

function MangaLibraryWidget:buildLibraryView()
    self.current_view = "library"
    
    -- Create title bar
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
    
    -- Build manga list
    local manga_list = self:getMangaList()
    
    -- Create content
    local content
    if #manga_list == 0 then
        local empty_text = TextWidget:new{
            text = _("No manga series found.\nUse the settings menu (⚙️) to add manga folders."),
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
    
    -- Build main widget
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
            local status_icon = (read_chapters == total_chapters) and "✓ " or "○ "
            
            table.insert(manga_list, {
                text = status_icon .. series_name .. " " .. progress_text,
                series_name = series_name,
                callback = function()
                    self:showChapterView(series_name)
                end
            })
        end
    end
    
    -- Add close option
    table.insert(manga_list, {
        text = "✕ " .. _("Close Manga Library"),
        callback = function()
            UIManager:close(self)
        end
    })
    
    return manga_list
end

function MangaLibraryWidget:showChapterView(series_name)
    self.current_view = "chapters"
    self.current_series = series_name
    
    local series_data = self.manga_library.reading_progress[series_name]
    if not series_data or not series_data.chapters then
        UIManager:show(InfoMessage:new{
            text = _("No chapters found for this series."),
        })
        return
    end
    
    -- Create title bar for chapter view
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
    
    -- Navigation and controls
    table.insert(chapter_list, {
        text = "← " .. _("Back to Library"),
        callback = function()
            self:buildLibraryView()
            UIManager:setDirty(self, "ui")
        end
    })
    
    table.insert(chapter_list, {
        text = "📖 " .. _("Mark All Read"),
        callback = function()
            self:markSeriesAsRead(series_name)
        end
    })
    
    table.insert(chapter_list, {
        text = "○ " .. _("Mark All Unread"),
        callback = function()
            self:markSeriesAsUnread(series_name)
        end
    })
    
    table.insert(chapter_list, {
        text = "────────────────────────",
        callback = function() end
    })
    
    -- Add chapters
    for i, chapter in ipairs(series_data.chapters) do
        local is_read = series_data.read_chapters and series_data.read_chapters[chapter.path]
        local status_icon = is_read and "✓" or "○"
        
        table.insert(chapter_list, {
            text = status_icon .. " " .. chapter.name,
            callback = function()
                self:openChapter(chapter, series_name, i)
            end,
            hold_callback = function()
                self:showChapterOptions(chapter, series_name)
            end
        })
    end
    
    -- Replace content
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
    
    -- Rebuild widget
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

function MangaLibraryWidget:showSettings()
    local buttons = {
        {
            {
                text = _("Add Manga Folder"),
                callback = function()
                    UIManager:close(self.settings_dialog)
                    self:addMangaFolder()
                end,
            },
            {
                text = _("Refresh Library"),
                callback = function()
                    UIManager:close(self.settings_dialog)
                    self:refreshLibrary()
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    UIManager:close(self.settings_dialog)
                end,
            },
        },
    }
    
    self.settings_dialog = ButtonDialog:new{
        title = _("Manga Library Settings"),
        title_align = "center",
        buttons = buttons,
    }
    
    UIManager:show(self.settings_dialog)
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
            
            -- Refresh view
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
            
            -- Refresh view
            UIManager:scheduleIn(0.2, function()
                self:showChapterView(series_name)
            end)
        end,
    })
end

function MangaLibraryWidget:addMangaFolder()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Add Manga Folder"),
        input_hint = _("Enter folder path (e.g., /mnt/us/manga/)"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Add"),
                    callback = function()
                        local folder_path = input_dialog:getInputText()
                        if folder_path and folder_path ~= "" then
                            self.manga_library:processFolder(folder_path)
                            UIManager:close(input_dialog)
                            self:refreshLibrary()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
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
        {
            {
                text = is_read and _("Mark as Unread") or _("Mark as Read"),
                callback = function()
                    UIManager:close(self.chapter_options_dialog)
                    self:toggleChapterReadStatus(chapter, series_name)
                end,
            },
        },
        {
            {
                text = _("Open Chapter"),
                callback = function()
                    UIManager:close(self.chapter_options_dialog)
                    self:openChapter(chapter, series_name)
                end,
            },
        },
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
    
    -- Refresh after short delay
    UIManager:scheduleIn(0.2, function()
        self:showChapterView(series_name)
    end)
end

function MangaLibraryWidget:openChapter(chapter, series_name, chapter_index)
    -- Mark as read
    if not self.manga_library.reading_progress[series_name].read_chapters then
        self.manga_library.reading_progress[series_name].read_chapters = {}
    end
    self.manga_library.reading_progress[series_name].read_chapters[chapter.path] = true
    self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
    self.manga_library.settings:flush()
    
    -- Close and open chapter
    UIManager:close(self)
    ReaderUI:showReader(chapter.path)
end

function MangaLibraryWidget:onClose()
    UIManager:close(self)
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

-- Keep existing MangaLibrary methods
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
    
    UIManager:show(InfoMessage:new{
        text = _("Manga folder added successfully!"),
    })
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
            logger.warn("MangaLibrary: Error processing folder", folder_path, err)
        end
    end
    
    UIManager:show(InfoMessage:new{
        text = _("Library refreshed! Processed ") .. processed_count .. _(" series."),
    })
end

return MangaLibrary
