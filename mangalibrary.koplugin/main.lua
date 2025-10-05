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
local util = require("util")
local _ = require("gettext")

-- NEW: Add networking support for MangaDEX
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local JSON = require("json")

local MangaLibrary = WidgetContainer:extend{
    name = "mangalibrary",
    is_doc_only = false,
}

local MangaLibraryWidget = InputContainer:extend{
    title = _("Manga Library"),
}

-- NEW: MangaDEX API Handler
local MangaDEXAPI = {
    base_url = "https://api.mangadx.org",
    rate_limit_delay = 1.0, -- Respect API rate limits
}

-- NEW: URL encoding function
function MangaDEXAPI:urlEncode(str)
    if not str then return "" end
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = string.gsub(str, " ", "%%20")
    return str
end

-- NEW: HTTP request wrapper with proper error handling
function MangaDEXAPI:makeRequest(url, callback)
    local response_body = {}
    local success, code, headers = pcall(function()
        return http.request{
            url = url,
            method = "GET",
            sink = ltn12.sink.table(response_body),
            headers = {
                ["User-Agent"] = "KOReader-MangaLibrary/1.0",
                ["Accept"] = "application/json"
            }
        }
    end)
    
    if success and code == 200 then
        local body = table.concat(response_body)
        local ok, data = pcall(JSON.decode, body)
        if ok then
            callback(data, nil)
        else
            callback(nil, _("Failed to parse response"))
        end
    else
        callback(nil, _("Network error: ") .. tostring(code))
    end
end

-- NEW: Search for manga on MangaDEX
function MangaDEXAPI:searchManga(query, callback)
    local url = self.base_url .. "/manga?title=" .. self:urlEncode(query) .. "&limit=10&contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica"
    self:makeRequest(url, callback)
end

-- NEW: Get chapters for a manga
function MangaDEXAPI:getChapters(manga_id, callback)
    local url = self.base_url .. "/chapter?manga=" .. manga_id .. "&translatedLanguage[]=en&order[chapter]=asc&limit=500&contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica"
    self:makeRequest(url, callback)
end

-- NEW: Get chapter images server information
function MangaDEXAPI:getChapterImages(chapter_id, callback)
    local url = self.base_url .. "/at-home/server/" .. chapter_id
    self:makeRequest(url, callback)
end

-- Existing initialization code
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
    
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    
    self:buildLibraryView()
    
    self.key_events = {
        Close = { { "Back" }, doc = "close manga library" },
    }
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
            text = _("No manga series found.\nUse the settings menu (⚙️) to manage folders or download manga from MangaDEX."),
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
    
    table.insert(manga_list, {
        text = "✕ " .. _("Close Manga Library"),
        callback = function()
            UIManager:close(self)
        end
    })
    
    return manga_list
end

-- ENHANCED: Settings menu with MangaDEX download option
function MangaLibraryWidget:showSettings()
    local folder_count = #self.manga_library.manga_folders
    local folder_text = folder_count > 0 and 
        _("Manage Folders") .. " (" .. folder_count .. ")" or 
        _("Manage Folders") .. " " .. _("(No folders added)")
    
    local buttons = {
        {
            {
                text = folder_text,
                callback = function()
                    UIManager:close(self.settings_dialog)
                    self:showFolderManagement()
                end,
            },
            {
                text = "📥 " .. _("Download from MangaDEX"),
                callback = function()
                    UIManager:close(self.settings_dialog)
                    self:showMangaDEXDownloader()
                end,
            },
        },
        {
            {
                text = _("Refresh Library"),
                callback = function()
                    UIManager:close(self.settings_dialog)
                    self:refreshLibrary()
                end,
            },
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

-- NEW: MangaDEX downloader interface
function MangaLibraryWidget:showMangaDEXDownloader()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Download Manga from MangaDEX"),
        input_hint = _("Enter manga name to search..."),
        description = _("Search and download manga directly from MangaDEX"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local manga_name = input_dialog:getInputText()
                        if manga_name and manga_name ~= "" then
                            UIManager:close(input_dialog)
                            self:searchMangaDEX(manga_name)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- NEW: Search manga on MangaDEX
function MangaLibraryWidget:searchMangaDEX(query)
    UIManager:show(InfoMessage:new{
        text = _("Searching MangaDEX for: ") .. query,
        timeout = 2,
    })
    
    MangaDEXAPI:searchManga(query, function(data, error)
        if error then
            UIManager:show(InfoMessage:new{
                text = _("Search failed: ") .. error,
                timeout = 3,
            })
            return
        end
        
        if not data or not data.data or #data.data == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No manga found for: ") .. query,
                timeout = 3,
            })
            return
        end
        
        self:showSearchResults(data.data)
    end)
end

-- NEW: Display search results
function MangaLibraryWidget:showSearchResults(manga_list)
    local search_results = {}
    
    for _, manga in ipairs(manga_list) do
        local title = manga.attributes.title.en or 
                     manga.attributes.title.ja or 
                     manga.attributes.title["ja-ro"] or 
                     _("Unknown Title")
        
        local description = manga.attributes.description.en or _("No description available")
        if #description > 100 then
            description = description:sub(1, 97) .. "..."
        end
        
        table.insert(search_results, {
            text = title,
            manga_data = manga,
            callback = function()
                self:showMangaDetails(manga, title)
            end
        })
    end
    
    -- Add back button
    table.insert(search_results, {
        text = "",
        callback = function() end
    })
    table.insert(search_results, {
        text = "← " .. _("Back to Download"),
        callback = function()
            UIManager:close(self.search_results_menu)
            self:showMangaDEXDownloader()
        end
    })
    
    self.search_results_menu = Menu:new{
        title = _("MangaDEX Search Results"),
        item_table = search_results,
        is_borderless = true,
        is_popout = false,
        width = self.width,
        height = self.height,
        close_callback = function()
            UIManager:close(self.search_results_menu)
        end,
    }
    
    UIManager:show(self.search_results_menu)
end

-- NEW: Show manga details and chapter options
function MangaLibraryWidget:showMangaDetails(manga_data, title)
    UIManager:close(self.search_results_menu)
    
    UIManager:show(InfoMessage:new{
        text = _("Loading chapters for: ") .. title,
        timeout = 2,
    })
    
    MangaDEXAPI:getChapters(manga_data.id, function(chapters_data, error)
        if error then
            UIManager:show(InfoMessage:new{
                text = _("Failed to load chapters: ") .. error,
                timeout = 3,
            })
            return
        end
        
        if not chapters_data or not chapters_data.data or #chapters_data.data == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No chapters found for this manga"),
                timeout = 3,
            })
            return
        end
        
        self:showChapterDownloadOptions(manga_data, title, chapters_data.data)
    end)
end

-- NEW: Chapter download selection interface
function MangaLibraryWidget:showChapterDownloadOptions(manga_data, title, chapters)
    local chapter_list = {}
    
    -- Add download options
    table.insert(chapter_list, {
        text = "📥 " .. _("Download All Chapters") .. " (" .. #chapters .. ")",
        callback = function()
            self:confirmDownloadChapters(manga_data, title, chapters)
        end
    })
    
    table.insert(chapter_list, {
        text = "📁 " .. _("Select Download Folder"),
        callback = function()
            self:selectDownloadFolder(manga_data, title, chapters)
        end
    })
    
    -- Add separator
    table.insert(chapter_list, {
        text = "",
        callback = function() end
    })
    
    -- Show first 10 chapters as preview
    local preview_count = math.min(10, #chapters)
    for i = 1, preview_count do
        local chapter = chapters[i]
        local chapter_title = chapter.attributes.title or ("Chapter " .. (chapter.attributes.chapter or i))
        
        table.insert(chapter_list, {
            text = "📄 " .. chapter_title,
            callback = function()
                self:downloadSingleChapter(manga_data, title, chapter)
            end
        })
    end
    
    if #chapters > 10 then
        table.insert(chapter_list, {
            text = "... and " .. (#chapters - 10) .. " more chapters",
            callback = function() end
        })
    end
    
    -- Add back button
    table.insert(chapter_list, {
        text = "",
        callback = function() end
    })
    table.insert(chapter_list, {
        text = "← " .. _("Back to Search"),
        callback = function()
            UIManager:close(self.chapter_options_menu)
            self:showSearchResults({manga_data})
        end
    })
    
    self.chapter_options_menu = Menu:new{
        title = title,
        item_table = chapter_list,
        is_borderless = true,
        is_popout = false,
        width = self.width,
        height = self.height,
        close_callback = function()
            UIManager:close(self.chapter_options_menu)
        end,
    }
    
    UIManager:show(self.chapter_options_menu)
end

-- NEW: Confirm download all chapters
function MangaLibraryWidget:confirmDownloadChapters(manga_data, title, chapters)
    UIManager:show(ConfirmBox:new{
        title = _("Download All Chapters?"),
        text = _("Download all ") .. #chapters .. _(" chapters of '") .. title .. _("'?\n\nThis may take a while and use significant storage space.\n\nNote: This is a proof of concept - actual download implementation needs image fetching and CBZ packaging."),
        ok_text = _("Download All"),
        ok_callback = function()
            -- Select folder or use default
            if #self.manga_library.manga_folders > 0 then
                self:startMangaDEXDownload(manga_data, title, chapters, self.manga_library.manga_folders[1])
            else
                self:selectDownloadFolder(manga_data, title, chapters)
            end
        end,
    })
end

-- NEW: Select download folder for MangaDEX content
function MangaLibraryWidget:selectDownloadFolder(manga_data, title, chapters)
    local folder_list = {}
    
    -- Show existing manga folders
    for _, folder_path in ipairs(self.manga_library.manga_folders) do
        table.insert(folder_list, {
            text = "📁 " .. folder_path,
            callback = function()
                UIManager:close(self.folder_select_menu)
                self:startMangaDEXDownload(manga_data, title, chapters, folder_path)
            end
        })
    end
    
    -- Option to browse for new folder
    table.insert(folder_list, {
        text = "",
        callback = function() end
    })
    table.insert(folder_list, {
        text = "🔍 " .. _("Browse for Folder"),
        callback = function()
            UIManager:close(self.folder_select_menu)
            self:browseFolderForDownload(manga_data, title, chapters)
        end
    })
    
    -- Back button
    table.insert(folder_list, {
        text = "",
        callback = function() end
    })
    table.insert(folder_list, {
        text = "← " .. _("Back"),
        callback = function()
            UIManager:close(self.folder_select_menu)
        end
    })
    
    self.folder_select_menu = Menu:new{
        title = _("Select Download Folder"),
        item_table = folder_list,
        is_borderless = true,
        is_popout = false,
        width = self.width,
        height = self.height,
        close_callback = function()
            UIManager:close(self.folder_select_menu)
        end,
    }
    
    UIManager:show(self.folder_select_menu)
end

-- NEW: Start MangaDEX download process
function MangaLibraryWidget:startMangaDEXDownload(manga_data, title, chapters, target_folder)
    UIManager:show(InfoMessage:new{
        text = _("Starting MangaDEX download of: ") .. title .. _("\nTarget: ") .. target_folder .. _("\n\nThis is a proof of concept implementation."),
        timeout = 5,
    })
    
    -- Create series folder
    local series_folder = target_folder .. "/" .. self:sanitizeFilename(title)
    local success = lfs.mkdir(series_folder)
    
    if not success then
        -- Try to create directory structure
        os.execute("mkdir -p '" .. series_folder .. "'")
    end
    
    -- In a complete implementation, you would:
    -- 1. Loop through each chapter
    -- 2. Get chapter image server info using MangaDEXAPI:getChapterImages()
    -- 3. Download each image from the MangaDEX CDN
    -- 4. Package images into CBZ format
    -- 5. Save to series_folder
    -- 6. Update reading_progress automatically
    
    -- For demonstration, create a placeholder file
    local info_file = series_folder .. "/README.txt"
    local file = io.open(info_file, "w")
    if file then
        file:write("MangaDEX Download Info\n")
        file:write("Title: " .. title .. "\n")
        file:write("Chapters: " .. #chapters .. "\n")
        file:write("Downloaded from: MangaDEX\n")
        file:write("Manga ID: " .. manga_data.id .. "\n")
        file:close()
    end
    
    UIManager:show(InfoMessage:new{
        text = _("Download framework ready!\n\nIn full implementation:\n• Fetch chapter images from MangaDEX CDN\n• Create CBZ archives\n• Add to library automatically\n\nPlaceholder info saved to: ") .. info_file,
        timeout = 8,
    })
    
    -- Refresh the library to show any new content
    UIManager:scheduleIn(3, function()
        self:refreshLibrary()
        self:buildLibraryView()
    end)
end

-- NEW: Download single chapter (proof of concept)
function MangaLibraryWidget:downloadSingleChapter(manga_data, title, chapter)
    local chapter_title = chapter.attributes.title or ("Chapter " .. (chapter.attributes.chapter or "Unknown"))
    
    UIManager:show(InfoMessage:new{
        text = _("Downloading single chapter: ") .. chapter_title .. _("\n\nThis is a proof of concept - full implementation would fetch images and create CBZ."),
        timeout = 4,
    })
    
    -- In full implementation, you would:
    -- 1. Call MangaDEXAPI:getChapterImages(chapter.id, callback)
    -- 2. Download all images from the returned CDN URLs
    -- 3. Create a CBZ file with the images
    -- 4. Save to appropriate manga series folder
end

-- NEW: Sanitize filename for safe file system usage
function MangaLibraryWidget:sanitizeFilename(filename)
    return filename:gsub("[<>:\"/\\|?*]", "_"):gsub("%s+", "_")
end

-- Existing folder management functions remain the same
function MangaLibraryWidget:showFolderManagement()
    local folder_list = {}
    
    table.insert(folder_list, {
        text = "➕ " .. _("Add New Folder"),
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
                text = "📁 " .. display_path,
                hold_callback = function()
                    self:showFolderOptions(folder_path, i)
                end,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Long press to manage this folder\n\nPath: ") .. folder_path,
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
        table.insert(folder_list, {
            text = _("Tap 'Add New Folder' to get started"),
            callback = function() end
        })
    end
    
    table.insert(folder_list, {
        text = "",
        callback = function() end
    })
    table.insert(folder_list, {
        text = "← " .. _("Back to Settings"),
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
        item_font_face = Font:getFace("smallinfofont"),
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
        {
            {
                text = _("Remove Folder"),
                callback = function()
                    if self.folder_options_dialog then
                        UIManager:close(self.folder_options_dialog)
                        self.folder_options_dialog = nil
                    end
                    self:confirmRemoveFolder(folder_path, folder_index)
                end,
            },
        },
        {
            {
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
            },
        },
    }
    
    self.folder_options_dialog = ButtonDialog:new{
        title = _("Manage: ") .. folder_name,
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
        "/mnt/ext1/",
        "/storage/emulated/0/",
        "/home/" .. (os.getenv("USER") or "user") .. "/",
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
    
    local display_path = folder_path
    if #display_path > 50 then
        display_path = "..." .. display_path:sub(-47)
    end
    
    UIManager:show(ConfirmBox:new{
        title = _("Add Manga Folder?"),
        text = display_path .. "\n\n" .. preview_text .. "\n\n" .. _("Add this folder to your library?"),
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
    local display_path = folder_path
    if #display_path > 50 then
        display_path = "..." .. display_path:sub(-47)
    end
    
    UIManager:show(ConfirmBox:new{
        title = _("Remove Folder?"),
        text = display_path .. "\n\n" .. 
               _("Remove this folder from your manga library?\n\n") ..
               _("(Files will not be deleted)"),
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

-- Existing chapter view and reading functions
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
        text = "",
        callback = function() end
    })
    
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
    
    UIManager:scheduleIn(0.2, function()
        self:showChapterView(series_name)
    end)
end

function MangaLibraryWidget:openChapter(chapter, series_name, chapter_index)
    if not self.manga_library.reading_progress[series_name].read_chapters then
        self.manga_library.reading_progress[series_name].read_chapters = {}
    end
    self.manga_library.reading_progress[series_name].read_chapters[chapter.path] = true
    self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
    self.manga_library.settings:flush()
    
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

-- Backend methods for processing local folders
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
            logger.warn("MangaLibrary: Error processing folder", folder_path, err)
        end
    end
    
    UIManager:show(InfoMessage:new{
        text = _("Library refreshed! Processed ") .. processed_count .. _(" series."),
    })
end

return MangaLibrary
