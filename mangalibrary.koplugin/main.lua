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

-- HTTP for MangaPill
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")

local GlobalState = {
    is_showing = false,
    current_series = nil,
    current_chapter_path = nil,
    error_log = {},
    download_queue = {},
    is_downloading = false,
    current_download = nil,
    downloading_chapters = {},
    active_widget = nil,
    downloading_message = nil,
    download_count = 0,
    completed_downloads = 0,
    batch_downloading = false,
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

-- FIXED: Safe CBZ creation using KOReader's built-in capabilities
local function createCBZ(chapter_folder, cbz_path)
    debugLog("Creating CBZ: " .. cbz_path)
    
    -- Method 1: Try KOReader's built-in zipwriter
    local success, zipwriter = pcall(require, "ffi/zipwriter")
    if success and zipwriter then
        debugLog("Using KOReader's zipwriter")
        local ok, zip = pcall(zipwriter.new, zipwriter, cbz_path)
        if ok and zip then
            local images = {}
            for file in lfs.dir(chapter_folder) do
                if file ~= "." and file ~= ".." and file:match("%.jpg$") then
                    table.insert(images, file)
                end
            end
            table.sort(images)
            
            for i, img in ipairs(images) do
                local full_path = chapter_folder .. "/" .. img
                local padded_name = string.format("%03d.jpg", i)
                pcall(zip.add, zip, padded_name, full_path)
            end
            
            pcall(zip.close, zip)
            
            if lfs.attributes(cbz_path) then
                debugLog("CBZ created successfully with zipwriter")
                return true
            end
        end
    end
    
    -- Method 2: Try system zip command (if available)
    debugLog("Trying system zip command")
    local zip_result = os.execute(string.format('cd "%s" && zip -q -j "%s" *.jpg 2>/dev/null', chapter_folder, cbz_path))
    if (zip_result == 0 or zip_result == true) and lfs.attributes(cbz_path) then
        debugLog("CBZ created successfully with system zip")
        return true
    end
    
    -- Method 3: Try tar (compressed)
    debugLog("Trying tar with compression")
    local tar_temp = cbz_path:gsub("%.cbz$", ".tar.gz")
    local tar_result = os.execute(string.format('cd "%s" && tar -czf "%s" *.jpg 2>/dev/null', chapter_folder, tar_temp))
    if (tar_result == 0 or tar_result == true) and lfs.attributes(tar_temp) then
        os.execute(string.format('mv "%s" "%s"', tar_temp, cbz_path))
        if lfs.attributes(cbz_path) then
            debugLog("CBZ created successfully with tar")
            return true
        end
    end
    
    -- Method 4: Create a simple folder structure that KOReader can read
    debugLog("All compression methods failed, using folder structure")
    -- Rename folder to have .cbz extension (KOReader can read this)
    local folder_as_cbz = cbz_path:gsub("%.cbz$", ".images")
    os.execute(string.format('mv "%s" "%s"', chapter_folder, folder_as_cbz))
    
    -- Create a symlink or marker
    os.execute(string.format('ln -s "%s" "%s" 2>/dev/null', folder_as_cbz, cbz_path))
    
    if lfs.attributes(folder_as_cbz) then
        debugLog("Using folder structure: " .. folder_as_cbz)
        -- Update the path to point to the folder
        return folder_as_cbz
    end
    
    debugLog("All methods failed")
    return false
end

-- Enhanced chapter number extraction with multiple patterns
local function extractChapterNumber(str)
    if not str then return 0 end
    
    str = str:gsub("[\194\160]", " ")
    str = str:gsub("%s+", " ")
    
    local patterns = {
        "Chapter%s+(%d+%.?%d*)",
        "Ch%.?%s+(%d+%.?%d*)",
        "Chap%.?%s+(%d+%.?%d*)",
        "#(%d+%.?%d*)",
        "^(%d+%.?%d*)%s*$",
        "^(%d+%.?%d*)[%s%-:]",
        "[^%d](%d+%.?%d*)$",
        "(%d+%.?%d*)",
    }
    
    for _, pattern in ipairs(patterns) do
        local num = str:match(pattern)
        if num then
            local parsed = tonumber(num)
            if parsed and parsed > 0 then
                return parsed
            end
        end
    end
    
    return 0
end

-- MangaPill API
local MangaPillAPI = {
    base_url = "https://mangapill.com",
}

function MangaPillAPI:makeRequest(path)
    local url = self.base_url .. path
    local response_body = {}
    local result, status_code = http.request{
        url = url,
        method = "GET",
        headers = {["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"},
        sink = ltn12.sink.table(response_body)
    }
    if result and status_code == 200 then
        return table.concat(response_body)
    end
    debugLog("HTTP request failed: " .. tostring(status_code))
    return nil
end

function MangaPillAPI:search(query)
    debugLog("Searching for: " .. query)
    local encoded = query:gsub(" ", "+")
    local html = self:makeRequest("/search?q=" .. encoded)
    if not html then 
        debugLog("Search request failed")
        return {} 
    end
    
    local results = {}
    
    for url, title in html:gmatch('<a%s+href="(/manga/[^"]+)"[^>]*>.-<div[^>]*>([^<]+)</div>') do
        local id = url:match("/manga/([^/]+)")
        if id then
            table.insert(results, {
                id = id,
                title = title:gsub("^%s*(.-)%s*$", "%1"),
                url = self.base_url .. url,
            })
            if #results >= 15 then break end
        end
    end
    
    if #results == 0 then
        for url in html:gmatch('href="(/manga/[^"]+)"') do
            local id = url:match("/manga/([^/]+)")
            if id then
                local title = id:gsub("%-", " "):gsub("(%a)(%w*)", function(a,b) return a:upper()..b end)
                table.insert(results, {
                    id = id,
                    title = title,
                    url = self.base_url .. url,
                })
                if #results >= 15 then break end
            end
        end
    end
    
    debugLog("Found " .. tostring(#results) .. " results")
    return results
end

function MangaPillAPI:getChapterList(manga_id)
    debugLog("Fetching chapters for: " .. manga_id)
    local html = self:makeRequest("/manga/" .. manga_id)
    if not html then 
        debugLog("Failed to get HTML")
        return {} 
    end
    
    local chapters = {}
    
    for url, title in html:gmatch('<a[^>]+href="(/chapters/[^"]+)"[^>]*>%s*([^<]+)%s*</a>') do
        local ch_num = extractChapterNumber(title)
        table.insert(chapters, {
            title = title:gsub("^%s*(.-)%s*$", "%1"),
            url = self.base_url .. url,
            chapter_id = url:match("/chapters/([^/]+)"),
            chapter_num = ch_num,
        })
    end
    
    if #chapters == 0 then
        for url, title in html:gmatch('data%-href="(/chapters/[^"]+)"[^>]*>%s*<[^>]+>([^<]+)</') do
            local ch_num = extractChapterNumber(title)
            table.insert(chapters, {
                title = title:gsub("^%s*(.-)%s*$", "%1"),
                url = self.base_url .. url,
                chapter_id = url:match("/chapters/([^/]+)"),
                chapter_num = ch_num,
            })
        end
    end
    
    if #chapters == 0 then
        for title, url in html:gmatch('<div[^>]*>([^<]+)</div>%s*<a[^>]+href="(/chapters/[^"]+)"') do
            local ch_num = extractChapterNumber(title)
            table.insert(chapters, {
                title = title:gsub("^%s*(.-)%s*$", "%1"),
                url = self.base_url .. url,
                chapter_id = url:match("/chapters/([^/]+)"),
                chapter_num = ch_num,
            })
        end
    end
    
    if #chapters == 0 then
        for url in html:gmatch('href="(/chapters/[^"]+)"') do
            local chapter_id = url:match("/chapters/([^/]+)")
            if chapter_id then
                local ch_num = extractChapterNumber(chapter_id)
                table.insert(chapters, {
                    title = "Chapter " .. chapter_id,
                    url = self.base_url .. url,
                    chapter_id = chapter_id,
                    chapter_num = ch_num,
                })
            end
        end
    end
    
    table.sort(chapters, function(a, b)
        local a_num = a.chapter_num or 0
        local b_num = b.chapter_num or 0
        if a_num == b_num then
            return (a.title or "") < (b.title or "")
        end
        return a_num < b_num
    end)
    
    debugLog("Sorted " .. tostring(#chapters) .. " chapters")
    return chapters
end

function MangaPillAPI:getChapterImages(chapter_url)
    local path = chapter_url:gsub(self.base_url, "")
    local html = self:makeRequest(path)
    if not html then return {} end
    local images = {}
    for img in html:gmatch('<img[^>]+data%-src="([^"]+)"') do
        table.insert(images, img)
    end
    if #images == 0 then
        for img in html:gmatch('<img[^>]+src="(https://[^"]+%.jpg[^"]*)"') do
            table.insert(images, img)
        end
    end
    return images
end

function MangaPillAPI:downloadImage(url, dest_path, referer)
    local response_body = {}
    local headers = {
        ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
    }
    
    if referer then
        headers["Referer"] = referer
    end
    
    local result, status_code = http.request{
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body)
    }
    
    if result and status_code == 200 then
        local file = io.open(dest_path, "wb")
        if file then
            file:write(table.concat(response_body))
            file:close()
            return true
        end
    end
    return false
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
    self.last_update_check = self.settings:readSetting("last_update_check") or 0
    debugLog("Registering to main menu")
    self.ui.menu:registerToMainMenu(self)
    
    self:checkForUpdates()
    
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

function MangaLibrary:checkForUpdates()
    local current_time = os.time()
    local week_in_seconds = 7 * 24 * 60 * 60
    
    if current_time - self.last_update_check < week_in_seconds then
        debugLog("Skipping update check - last checked recently")
        return
    end
    
    debugLog("Checking for manga updates...")
    self.last_update_check = current_time
    self.settings:saveSetting("last_update_check", current_time)
    self.settings:flush()
    
    local updates_found = 0
    for series_name, series_data in pairs(self.reading_progress) do
        if series_data.manga_id and series_data.online_chapters then
            local new_chapters = MangaPillAPI:getChapterList(series_data.manga_id)
            if #new_chapters > #series_data.online_chapters then
                updates_found = updates_found + (#new_chapters - #series_data.online_chapters)
                series_data.online_chapters = new_chapters
                debugLog("Found " .. tostring(#new_chapters - #series_data.online_chapters) .. " new chapters for " .. series_name)
            end
        end
    end
    
    if updates_found > 0 then
        self.settings:saveSetting("reading_progress", self.reading_progress)
        self.settings:flush()
        UIManager:show(InfoMessage:new{
            text = "Found " .. tostring(updates_found) .. " new chapters!",
            timeout = 3,
        })
    end
end

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

function MangaLibrary:onEndOfBook()
    debugLog(">>> onEndOfBook CALLED <<<")
    
    if not GlobalState.is_showing then
        debugLog("is_showing=false, not handling")
        return false
    end
    
    if not (GlobalState.current_series and GlobalState.current_chapter_path) then
        debugLog("No current series/chapter")
        return false
    end
    
    self:markChapter(GlobalState.current_series, GlobalState.current_chapter_path, true)
    
    local next_chapter = self:getNextChapter(GlobalState.current_series, GlobalState.current_chapter_path)
    
    if not next_chapter then
        local series_data = self.reading_progress[GlobalState.current_series]
        if series_data and series_data.manga_id and series_data.online_chapters then
            local next_online = self:getNextOnlineChapter(GlobalState.current_series)
            if next_online then
                debugLog("Auto-downloading next chapter: " .. next_online.title)
                
                GlobalState.downloading_message = InfoMessage:new{
                    text = "Downloading next chapter...\n" .. next_online.title,
                    timeout = false,
                }
                UIManager:show(GlobalState.downloading_message)
                
                self:downloadAndOpenChapter(GlobalState.current_series, next_online, GlobalState.downloading_message)
                return true
            end
        end
        
        debugLog("No next chapter")
        GlobalState.is_showing = false
        UIManager:show(InfoMessage:new{
            text = _("All downloaded chapters complete!"),
            timeout = 2,
        })
        return true
    end
    
    debugLog("Switching to: " .. next_chapter.name)
    self:show({series = GlobalState.current_series, path = next_chapter.path})
    UIManager:show(InfoMessage:new{
        text = _("Next: ") .. next_chapter.name,
        timeout = 1,
    })
    return true
end

function MangaLibrary:getNextOnlineChapter(series_name)
    local series_data = self.reading_progress[series_name]
    if not series_data or not series_data.online_chapters then
        return nil
    end
    
    local downloaded_nums = {}
    if series_data.chapters then
        for _, ch in ipairs(series_data.chapters) do
            local num = extractChapterNumber(ch.name)
            downloaded_nums[num] = true
        end
    end
    
    for _, online_ch in ipairs(series_data.online_chapters) do
        if not downloaded_nums[online_ch.chapter_num or 0] then
            return online_ch
        end
    end
    
    return nil
end

function MangaLibrary:downloadAndOpenChapter(series_name, chapter, loading_msg)
    local series_data = self.reading_progress[series_name]
    if not series_data then return end
    
    local manga = {
        title = series_name,
        id = series_data.manga_id
    }
    
    local download_base = self.manga_folders[1] or DataStorage:getDataDir() .. "/manga"
    local series_folder = download_base .. "/" .. series_name:gsub("[^%w%s%-]", "")
    local chapter_folder = series_folder .. "/" .. chapter.title:gsub("[^%w%s%-]", "")
    
    os.execute("mkdir -p '" .. chapter_folder .. "'")
    
    local images = MangaPillAPI:getChapterImages(chapter.url)
    
    if #images == 0 then
        UIManager:close(loading_msg)
        GlobalState.downloading_message = nil
        UIManager:show(InfoMessage:new{
            text = "Failed to download next chapter",
            timeout = 2,
        })
        return
    end
    
    for i, img_url in ipairs(images) do
        MangaPillAPI:downloadImage(img_url, string.format("%s/%03d.jpg", chapter_folder, i), chapter.url)
    end
    
    local cbz_path = series_folder .. "/" .. chapter.title:gsub("[^%w%s%-]", "") .. ".cbz"
    
    local result = createCBZ(chapter_folder, cbz_path)
    if result then
        local final_path = type(result) == "string" and result or cbz_path
        if type(result) ~= "string" then
            os.execute("rm -rf '" .. chapter_folder .. "'")
        end
        self:refreshSpecificSeries(series_name)
        UIManager:close(loading_msg)
        GlobalState.downloading_message = nil
        self:show({series = series_name, path = final_path})
        UIManager:show(InfoMessage:new{
            text = "Next: " .. chapter.title,
            timeout = 1,
        })
    else
        UIManager:close(loading_msg)
        GlobalState.downloading_message = nil
        UIManager:show(InfoMessage:new{
            text = "Failed to create chapter file",
            timeout = 2,
        })
    end
end

function MangaLibrary:getNextChapter(series_name, current_path)
    local series_data = self.reading_progress[series_name]
    if not series_data or not series_data.chapters then
        return nil
    end
    
    for i, chapter in ipairs(series_data.chapters) do
        if chapter.path == current_path and i < #series_data.chapters then
            return series_data.chapters[i + 1]
        end
    end
    
    return nil
end

function MangaLibrary:onReaderUiCloseWidget()
    debugLog("ReaderUI closing, resetting is_showing")
    GlobalState.is_showing = false
    if GlobalState.downloading_message then
        UIManager:close(GlobalState.downloading_message)
        GlobalState.downloading_message = nil
    end
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
    GlobalState.active_widget = manga_widget
    UIManager:show(manga_widget)
end

function MangaLibrary:refreshSpecificSeries(series_name)
    local series_data = self.reading_progress[series_name]
    if not series_data or not series_data.folder_path then
        debugLog("Cannot refresh series: no folder path")
        return
    end
    
    debugLog("Refreshing series: " .. series_name)
    self:processMangaSeries(series_data.folder_path, series_name)
    
    if GlobalState.active_widget and GlobalState.active_widget.current_view == "chapters" 
        and GlobalState.active_widget.current_series == series_name then
        GlobalState.active_widget:showChapterView(series_name)
    end
end

function MangaLibraryWidget:init()
    self.manga_library = self.manga_library or {}
    self.current_view = "library"
    self.current_series = nil
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.library_cache = nil
    self.cache_valid = false
    self:buildLibraryView()
    self.key_events = {
        Close = { { "Back" }, doc = "close manga library" },
    }
    debugLog("MangaLibraryWidget initialized")
end

function MangaLibraryWidget:buildLibraryView()
    self.current_view = "library"
    
    if self.cache_valid and self.library_cache then
        self[1] = self.library_cache
        UIManager:setDirty(self, "ui")
        return
    end
    
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
            show_parent = self,
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
    
    self.library_cache = self[1]
    self.cache_valid = true
end

function MangaLibraryWidget:getMangaList()
    local manga_list = {}
    
    for series_name, series_data in pairs(self.manga_library.reading_progress) do
        if not series_name:match("%.sdr$") then
            local total_chapters = 0
            local read_chapters = 0
            
            if series_data.chapters and #series_data.chapters > 0 then
                total_chapters = #series_data.chapters
                for _, chapter in ipairs(series_data.chapters) do
                    if series_data.read_chapters and series_data.read_chapters[chapter.path] then
                        read_chapters = read_chapters + 1
                    end
                end
            elseif series_data.online_chapters and #series_data.online_chapters > 0 then
                total_chapters = #series_data.online_chapters
            end
            
            if total_chapters > 0 then
                local progress_text = "(" .. read_chapters .. "/" .. total_chapters .. ")"
                local status_icon = (read_chapters == total_chapters and total_chapters > 0) and "[✓] " or "[ ] "
                
                table.insert(manga_list, {
                    text = status_icon .. series_name .. " " .. progress_text,
                    series_name = series_name,
                    callback = function()
                        self:showChapterView(series_name)
                    end
                })
            end
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
    self.current_view = "settings"
    
    local title_bar = TitleBar:new{
        width = self.width,
        align = "center",
        title = _("Settings"),
        title_face = Font:getFace("x_smalltfont"),
        left_icon = "appbar.back",
        left_icon_tap_callback = function()
            self:buildLibraryView()
            UIManager:setDirty(self, "ui")
        end,
    }
    
    local folder_count = #self.manga_library.manga_folders
    local folder_text = folder_count > 0 and
        _("Manage Folders") .. " (" .. folder_count .. ")" or
        _("Manage Folders")
    
    local queue_text = "Download Queue"
    if #GlobalState.download_queue > 0 then
        queue_text = queue_text .. " (" .. tostring(#GlobalState.download_queue) .. ")"
    end
    
    local settings_items = {
        {
            text = folder_text,
            callback = function()
                self:showFolderManagement()
            end,
        },
        {
            text = _("Manage Series"),
            callback = function()
                self:showManageSeriesScreen()
            end,
        },
        {
            text = _("Search MangaPill"),
            callback = function()
                self:showMangaPillSearch()
            end,
        },
        {
            text = queue_text,
            callback = function()
                self:showDownloadQueue()
            end,
        },
        {
            text = _("Check for Updates"),
            callback = function()
                self.manga_library:checkForUpdates()
            end,
        },
        {
            text = _("Refresh Library"),
            callback = function()
                self:refreshLibrary()
            end,
        },
        {
            text = _("View Error Log"),
            callback = function()
                self:showErrorLog()
            end,
        },
        {
            text = _("Return to Library"),
            callback = function()
                self:buildLibraryView()
                UIManager:setDirty(self, "ui")
            end,
        },
    }
    
    local content = Menu:new{
        item_table = settings_items,
        is_borderless = true,
        is_popout = false,
        show_parent = self,
        width = self.width,
        height = self.height - title_bar:getHeight(),
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

function MangaLibraryWidget:showMangaPillSearch()
    local input_dlg
    input_dlg = InputDialog:new{
        title = "Search MangaPill",
        input = "",
        buttons = {
            {
                {text = "Cancel", callback = function() UIManager:close(input_dlg) end},
                {text = "Search", is_enter_default = true, callback = function()
                    local query = input_dlg:getInputText()
                    UIManager:close(input_dlg)
                    if query and query ~= "" then
                        UIManager:show(InfoMessage:new{text = "Searching...", timeout = 1})
                        local results = MangaPillAPI:search(query)
                        if #results == 0 then
                            UIManager:show(InfoMessage:new{text = "No results found", timeout = 2})
                            return
                        end
                        self:showMangaPillResults(results)
                    end
                end},
            },
        },
    }
    UIManager:show(input_dlg)
    input_dlg:onShowKeyboard()
end

function MangaLibraryWidget:showMangaPillResults(results)
    local title_bar = TitleBar:new{
        width = self.width,
        title = "Search Results",
        title_face = Font:getFace("x_smalltfont"),
    }
    
    local widget = self
    local results_list = {}
    table.insert(results_list, {text = "< Back", callback = function() widget:buildLibraryView() end})
    
    for _, manga in ipairs(results) do
        local m = manga
        table.insert(results_list, {
            text = m.title,
            callback = function()
                UIManager:show(InfoMessage:new{text = "Loading chapters...", timeout = 1})
                local chapters = MangaPillAPI:getChapterList(m.id)
                if #chapters == 0 then
                    UIManager:show(InfoMessage:new{text = "No chapters found", timeout = 2})
                    return
                end
                widget:showMangaPillChapters(m, chapters)
            end
        })
    end
    
    local content = Menu:new{
        item_table = results_list,
        is_borderless = true,
        is_popout = false,
        show_parent = self,
        width = self.width,
        height = self.height - title_bar:getHeight(),
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

function MangaLibraryWidget:showMangaPillChapters(manga, chapters)
    local title_bar = TitleBar:new{
        width = self.width,
        title = manga.title,
        title_face = Font:getFace("x_smalltfont"),
    }
    
    local widget = self
    local m = manga
    local ch = chapters
    
    local chapter_list = {}
    table.insert(chapter_list, {text = "< Back", callback = function() widget:buildLibraryView() end})
    table.insert(chapter_list, {
        text = "[+] Add to Library",
        callback = function()
            widget:addMangaToLibrary(m, ch)
        end
    })
    table.insert(chapter_list, {
        text = "Download All Chapters",
        callback = function()
            widget:downloadMultipleChapters(m, ch)
        end
    })
    table.insert(chapter_list, {
        text = "Download Range (1-10)",
        callback = function()
            widget:showDownloadRangeDialog(m, ch)
        end
    })
    
    for _, chapter in ipairs(chapters) do
        local c = chapter
        table.insert(chapter_list, {
            text = "[ONLINE] " .. c.title,
            callback = function()
                widget:showChapterDownloadOptions(m, c)
            end
        })
    end
    
    local content = Menu:new{
        item_table = chapter_list,
        is_borderless = true,
        is_popout = false,
        show_parent = self,
        width = self.width,
        height = self.height - title_bar:getHeight(),
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

function MangaLibraryWidget:showDownloadRangeDialog(manga, chapters)
    local widget = self
    local m = manga
    local ch = chapters
    
    local input_dlg
    input_dlg = InputDialog:new{
        title = "Download Chapter Range",
        input_hint = "e.g. 1-10 or 5-15",
        input = "1-10",
        buttons = {
            {
                {text = "Cancel", callback = function() UIManager:close(input_dlg) end},
                {text = "Download", is_enter_default = true, callback = function()
                    local range = input_dlg:getInputText()
                    UIManager:close(input_dlg)
                    
                    local start_ch, end_ch = range:match("(%d+)%-(%d+)")
                    start_ch = tonumber(start_ch)
                    end_ch = tonumber(end_ch)
                    
                    if start_ch and end_ch and start_ch <= end_ch and start_ch >= 1 and end_ch <= #ch then
                        GlobalState.batch_downloading = true
                        GlobalState.download_count = end_ch - start_ch + 1
                        GlobalState.completed_downloads = 0
                        
                        GlobalState.downloading_message = InfoMessage:new{
                            text = "Downloading " .. tostring(GlobalState.download_count) .. " chapters in background...\nDo not close the app.",
                            timeout = false,
                        }
                        UIManager:show(GlobalState.downloading_message)
                        
                        for i = start_ch, end_ch do
                            widget:queueDownload(m, ch[i], true)
                        end
                    else
                        UIManager:show(InfoMessage:new{
                            text = "Invalid range. Use format: 1-10",
                            timeout = 2,
                        })
                    end
                end},
            },
        },
    }
    UIManager:show(input_dlg)
    input_dlg:onShowKeyboard()
end

function MangaLibraryWidget:addMangaToLibrary(manga, chapters)
    local download_base = self.manga_library.manga_folders[1] or DataStorage:getDataDir() .. "/manga"
    
    os.execute("mkdir -p '" .. download_base .. "'")
    
    if #self.manga_library.manga_folders == 0 then
        table.insert(self.manga_library.manga_folders, download_base)
        self.manga_library.settings:saveSetting("manga_folders", self.manga_library.manga_folders)
    end
    
    local series_folder = download_base .. "/" .. manga.title:gsub("[^%w%s%-]", "")
    
    os.execute("mkdir -p '" .. series_folder .. "'")
    
    self.manga_library.reading_progress[manga.title] = {
        chapters = {},
        read_chapters = {},
        online_chapters = chapters,
        manga_id = manga.id,
        folder_path = series_folder,
    }
    
    self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
    self.manga_library.settings:flush()
    
    self.cache_valid = false
    
    debugLog("Added " .. manga.title .. " to library with " .. tostring(#chapters) .. " online chapters")
    
    UIManager:show(InfoMessage:new{
        text = "Added " .. manga.title .. " to library!\n" .. tostring(#chapters) .. " chapters available online.",
        timeout = 2,
    })
    
    UIManager:scheduleIn(0.3, function()
        self:buildLibraryView()
    end)
end

function MangaLibraryWidget:showChapterDownloadOptions(manga, chapter)
    local widget = self
    local m = manga
    local c = chapter
    
    local buttons = {
        {{
            text = "Download Chapter",
            callback = function()
                UIManager:close(widget.chapter_download_dialog)
                
                UIManager:show(InfoMessage:new{
                    text = "Downloading in background...",
                    timeout = 1,
                })
                
                widget:queueDownload(m, c, true)
            end,
        }},
        {{
            text = "Cancel",
            callback = function()
                UIManager:close(widget.chapter_download_dialog)
            end,
        }},
    }
    
    self.chapter_download_dialog = ButtonDialog:new{
        title = chapter.title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.chapter_download_dialog)
end

function MangaLibraryWidget:queueDownload(manga, chapter, background_mode)
    local key = manga.title .. ":" .. chapter.title
    GlobalState.downloading_chapters[key] = true
    
    table.insert(GlobalState.download_queue, {
        manga = manga,
        chapter = chapter,
        status = "queued",
        background = background_mode or false,
    })
    
    if not GlobalState.is_downloading then
        self:processDownloadQueue()
    end
end

function MangaLibraryWidget:processDownloadQueue()
    if #GlobalState.download_queue == 0 then
        GlobalState.is_downloading = false
        GlobalState.current_download = nil
        
        if GlobalState.batch_downloading then
            if GlobalState.downloading_message then
                UIManager:close(GlobalState.downloading_message)
            end
            GlobalState.downloading_message = InfoMessage:new{
                text = "Downloads Complete!\n" .. tostring(GlobalState.completed_downloads) .. " chapters downloaded.",
                timeout = 3,
            }
            UIManager:show(GlobalState.downloading_message)
            GlobalState.batch_downloading = false
            GlobalState.download_count = 0
            GlobalState.completed_downloads = 0
        end
        return
    end
    
    GlobalState.is_downloading = true
    local download_item = GlobalState.download_queue[1]
    GlobalState.current_download = download_item
    download_item.status = "downloading"
    
    UIManager:scheduleIn(0.1, function()
        self:downloadChapter(download_item.manga, download_item.chapter, download_item.background, function()
            table.remove(GlobalState.download_queue, 1)
            
            if GlobalState.batch_downloading then
                GlobalState.completed_downloads = GlobalState.completed_downloads + 1
                
                if GlobalState.downloading_message then
                    UIManager:close(GlobalState.downloading_message)
                    GlobalState.downloading_message = InfoMessage:new{
                        text = "Downloading chapters... (" .. tostring(GlobalState.completed_downloads) .. "/" .. tostring(GlobalState.download_count) .. ")\nDo not close the app.",
                        timeout = false,
                    }
                    UIManager:show(GlobalState.downloading_message)
                end
            end
            
            self:processDownloadQueue()
        end)
    end)
end

function MangaLibraryWidget:downloadChapter(manga, chapter, background_mode, callback)
    local download_base = self.manga_library.manga_folders[1] or DataStorage:getDataDir() .. "/manga"
    local series_folder = download_base .. "/" .. manga.title:gsub("[^%w%s%-]", "")
    local chapter_folder = series_folder .. "/" .. chapter.title:gsub("[^%w%s%-]", "")
    
    os.execute("mkdir -p '" .. chapter_folder .. "'")
    
    debugLog("Downloading chapter: " .. chapter.title)
    
    local images = MangaPillAPI:getChapterImages(chapter.url)
    
    if #images == 0 then
        debugLog("No images found for chapter")
        local key = manga.title .. ":" .. chapter.title
        GlobalState.downloading_chapters[key] = nil
        if callback then callback() end
        return
    end
    
    local downloaded = 0
    for i, img_url in ipairs(images) do
        local dest = string.format("%s/%03d.jpg", chapter_folder, i)
        local success = MangaPillAPI:downloadImage(img_url, dest, chapter.url)
        if success then
            downloaded = downloaded + 1
        end
    end
    
    if downloaded == 0 then
        os.execute("rm -rf '" .. chapter_folder .. "'")
        local key = manga.title .. ":" .. chapter.title
        GlobalState.downloading_chapters[key] = nil
        if callback then callback() end
        return
    end
    
    local cbz_path = series_folder .. "/" .. chapter.title:gsub("[^%w%s%-]", "") .. ".cbz"
    
    local result = createCBZ(chapter_folder, cbz_path)
    
    if result then
        if type(result) ~= "string" then
            os.execute("rm -rf '" .. chapter_folder .. "'")
        end
        debugLog("Chapter packaged successfully")
        
        self.manga_library:refreshSpecificSeries(manga.title)
        self.cache_valid = false
        
        if background_mode and not GlobalState.batch_downloading then
            UIManager:show(InfoMessage:new{
                text = "Download Complete:\n" .. manga.title .. "\n" .. chapter.title,
                timeout = 2,
            })
        end
    else
        os.execute("rm -rf '" .. chapter_folder .. "'")
        debugLog("Failed to package chapter")
    end
    
    local key = manga.title .. ":" .. chapter.title
    GlobalState.downloading_chapters[key] = nil
    
    if callback then callback() end
end

function MangaLibraryWidget:downloadMultipleChapters(manga, chapters)
    local widget = self
    local m = manga
    local ch = chapters
    
    UIManager:show(ConfirmBox:new{
        text = "Download all " .. tostring(#chapters) .. " chapters in background?",
        ok_text = "Download All",
        ok_callback = function()
            GlobalState.batch_downloading = true
            GlobalState.download_count = #chapters
            GlobalState.completed_downloads = 0
            
            GlobalState.downloading_message = InfoMessage:new{
                text = "Downloading " .. tostring(#chapters) .. " chapters in background...\nDo not close the app.",
                timeout = false,
            }
            UIManager:show(GlobalState.downloading_message)
            
            for _, chapter in ipairs(ch) do
                widget:queueDownload(m, chapter, true)
            end
        end,
    })
end

function MangaLibraryWidget:showDownloadQueue()
    local title_bar = TitleBar:new{
        width = self.width,
        title = "Download Queue",
        title_face = Font:getFace("x_smalltfont"),
    }
    
    local widget = self
    local queue_list = {}
    table.insert(queue_list, {text = "< Back", callback = function() widget:showSettings() end})
    
    if #GlobalState.download_queue == 0 then
        table.insert(queue_list, {text = "Queue is empty", callback = function() end})
    else
        for i, item in ipairs(GlobalState.download_queue) do
            local status = item.status == "downloading" and "[↓] " or "[QUEUE] "
            table.insert(queue_list, {
                text = status .. item.chapter.title,
                callback = function() end
            })
        end
    end
    
    table.insert(queue_list, {
        text = "Clear Queue",
        callback = function()
            GlobalState.download_queue = {}
            GlobalState.downloading_chapters = {}
            GlobalState.batch_downloading = false
            GlobalState.download_count = 0
            GlobalState.completed_downloads = 0
            if GlobalState.downloading_message then
                UIManager:close(GlobalState.downloading_message)
                GlobalState.downloading_message = nil
            end
            widget:showDownloadQueue()
        end
    })
    
    local content = Menu:new{
        item_table = queue_list,
        is_borderless = true,
        is_popout = false,
        show_parent = self,
        width = self.width,
        height = self.height - title_bar:getHeight(),
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

function MangaLibraryWidget:confirmDeleteSeries(series_name)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this manga from library?\n\n") .. series_name .. _("\n\nFiles will NOT be deleted from storage."),
        ok_text = _("Delete"),
        ok_callback = function()
            self.manga_library.reading_progress[series_name] = nil
            self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
            self.manga_library.settings:flush()
            self.cache_valid = false
            UIManager:show(InfoMessage:new{
                text = _("Series removed from library."),
                timeout = 2,
            })
            UIManager:scheduleIn(0.3, function()
                if self.current_view == "manage_series" then
                    self:showManageSeriesScreen()
                else
                    self:buildLibraryView()
                end
            end)
        end,
    })
end

function MangaLibraryWidget:showManageSeriesScreen()
    self.current_view = "manage_series"
    local title_bar = TitleBar:new{
        width = self.width,
        align = "center",
        title = _("Manage Series"),
        title_face = Font:getFace("x_smalltfont"),
        left_icon = "appbar.back",
        left_icon_tap_callback = function()
            self:showSettings()
        end,
    }
    local series_list = {}
    table.insert(series_list, {
        text = "< Return to Settings",
        callback = function()
            self:showSettings()
        end
    })
    
    local series_names = {}
    for series_name, _ in pairs(self.manga_library.reading_progress) do
        if not series_name:match("%.sdr$") then
            table.insert(series_names, series_name)
        end
    end
    table.sort(series_names)
    
    for _, series_name in ipairs(series_names) do
        table.insert(series_list, {
            text = "[DELETE] " .. series_name,
            callback = function()
                self:confirmDeleteSeries(series_name)
            end
        })
    end
    
    if #series_names == 0 then
        table.insert(series_list, {
            text = _("No series in library"),
            callback = function() end
        })
    end
    
    local content = Menu:new{
        item_table = series_list,
        is_borderless = true,
        is_popout = false,
        show_parent = self,
        width = self.width,
        height = self.height - title_bar:getHeight(),
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
        for i, folder_path in ipairs(self.manga_library.manga_folders) do
            local display_path = folder_path
            if #display_path > 40 then
                display_path = "..." .. display_path:sub(-37)
            end
            
            table.insert(folder_list, {
                text = "[DELETE] " .. display_path,
                callback = function()
                    self:showFolderOptions(folder_path, i)
                end
            })
        end
    else
        table.insert(folder_list, {
            text = _("No folders added yet"),
            callback = function() end
        })
    end
    
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
        }},
        {{
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
        os.getenv("HOME") or "/home",
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
            self.cache_valid = false
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
        text = folder_path .. "\n\n" .. _("Files will not be deleted.\nManga from this folder will be removed from library."),
        ok_text = _("Remove"),
        ok_callback = function()
            local series_to_remove = {}
            for series_name, series_data in pairs(self.manga_library.reading_progress) do
                if series_data.folder_path and series_data.folder_path:find(folder_path, 1, true) then
                    table.insert(series_to_remove, series_name)
                end
                if series_data.chapters then
                    for _, chapter in ipairs(series_data.chapters) do
                        if chapter.path:find(folder_path, 1, true) then
                            table.insert(series_to_remove, series_name)
                            break
                        end
                    end
                end
            end
            
            for _, series_name in ipairs(series_to_remove) do
                self.manga_library.reading_progress[series_name] = nil
                debugLog("Removed series from library: " .. series_name)
            end
            
            table.remove(self.manga_library.manga_folders, folder_index)
            self.manga_library.settings:saveSetting("manga_folders", self.manga_library.manga_folders)
            self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
            self.manga_library.settings:flush()
            self.cache_valid = false
            
            local removed_count = #series_to_remove
            local message = removed_count > 0 and
                _("Folder removed. ") .. tostring(removed_count) .. _(" series removed from library.") or
                _("Folder removed from library.")
            
            UIManager:show(InfoMessage:new{
                text = message,
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
    if not series_data then
        UIManager:show(InfoMessage:new{
            text = _("No data for this series."),
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
    
    if series_data.online_chapters and series_data.manga_id then
        table.insert(chapter_list, {
            text = "Download Next X Unread Chapters",
            callback = function()
                self:showDownloadNextUnreadDialog(series_name)
            end
        })
    end
    
    table.insert(chapter_list, {
        text = _("Delete This Series"),
        callback = function()
            self:confirmDeleteSeries(series_name)
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
    
    local all_chapters = {}
    
    local downloaded_nums = {}
    if series_data.chapters then
        for _, chapter in ipairs(series_data.chapters) do
            local ch_num = extractChapterNumber(chapter.name)
            downloaded_nums[ch_num] = true
            
            table.insert(all_chapters, {
                type = "downloaded",
                chapter = chapter,
                chapter_num = ch_num,
                is_read = series_data.read_chapters and series_data.read_chapters[chapter.path],
            })
        end
    end
    
    if series_data.online_chapters then
        for _, online_ch in ipairs(series_data.online_chapters) do
            if not downloaded_nums[online_ch.chapter_num or 0] then
                local key = series_name .. ":" .. online_ch.title
                
                table.insert(all_chapters, {
                    type = "online",
                    chapter = online_ch,
                    chapter_num = online_ch.chapter_num or 0,
                    is_downloading = GlobalState.downloading_chapters[key],
                })
            end
        end
    end
    
    table.sort(all_chapters, function(a, b)
        local a_num = a.chapter_num or 0
        local b_num = b.chapter_num or 0
        if a_num == b_num then
            if a.type == "downloaded" and b.type ~= "downloaded" then
                return true
            elseif a.type ~= "downloaded" and b.type == "downloaded" then
                return false
            end
            return false
        end
        return a_num < b_num
    end)
    
    debugLog("Unified chapter list: " .. tostring(#all_chapters) .. " chapters")
    if #all_chapters > 0 then
        debugLog("First chapter num: " .. tostring(all_chapters[1].chapter_num))
        debugLog("Last chapter num: " .. tostring(all_chapters[#all_chapters].chapter_num))
    end
    
    for _, ch_info in ipairs(all_chapters) do
        if ch_info.type == "downloaded" then
            local status_icon = ch_info.is_read and "[✓] " or "[ ] "
            table.insert(chapter_list, {
                text = status_icon .. ch_info.chapter.name,
                callback = function()
                    self:openChapter(ch_info.chapter, series_name)
                end,
                hold_callback = function()
                    self:showChapterOptions(ch_info.chapter, series_name)
                end
            })
        else
            local icon = ch_info.is_downloading and "[↓] " or "[🌐] "
            table.insert(chapter_list, {
                text = icon .. ch_info.chapter.title,
                callback = function()
                    local m = {title = series_name, id = series_data.manga_id}
                    self:showChapterDownloadOptions(m, ch_info.chapter)
                end
            })
        end
    end
    
    local content = Menu:new{
        item_table = chapter_list,
        is_borderless = true,
        is_popout = false,
        show_parent = self,
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

function MangaLibraryWidget:showDownloadNextUnreadDialog(series_name)
    local widget = self
    local series_data = self.manga_library.reading_progress[series_name]
    
    local input_dlg
    input_dlg = InputDialog:new{
        title = "Download Next X Unread Chapters",
        input_hint = "e.g. 5 or 10",
        input = "5",
        buttons = {
            {
                {text = "Cancel", callback = function() UIManager:close(input_dlg) end},
                {text = "Download", is_enter_default = true, callback = function()
                    local count = tonumber(input_dlg:getInputText())
                    UIManager:close(input_dlg)
                    
                    if not count or count < 1 then
                        UIManager:show(InfoMessage:new{
                            text = "Please enter a valid number",
                            timeout = 2,
                        })
                        return
                    end
                    
                    local downloaded_nums = {}
                    if series_data.chapters then
                        for _, ch in ipairs(series_data.chapters) do
                            local num = extractChapterNumber(ch.name)
                            downloaded_nums[num] = true
                        end
                    end
                    
                    local to_download = {}
                    
                    for _, online_ch in ipairs(series_data.online_chapters or {}) do
                        if not downloaded_nums[online_ch.chapter_num or 0] and #to_download < count then
                            table.insert(to_download, online_ch)
                        end
                    end
                    
                    if #to_download == 0 then
                        UIManager:show(InfoMessage:new{
                            text = "All chapters already downloaded",
                            timeout = 2,
                        })
                        return
                    end
                    
                    GlobalState.batch_downloading = true
                    GlobalState.download_count = #to_download
                    GlobalState.completed_downloads = 0
                    
                    GlobalState.downloading_message = InfoMessage:new{
                        text = "Downloading " .. tostring(#to_download) .. " chapters in background...\nDo not close the app.",
                        timeout = false,
                    }
                    UIManager:show(GlobalState.downloading_message)
                    
                    local m = {title = series_name, id = series_data.manga_id}
                    for _, chapter in ipairs(to_download) do
                        widget:queueDownload(m, chapter, true)
                    end
                end},
            },
        },
    }
    UIManager:show(input_dlg)
    input_dlg:onShowKeyboard()
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
    self.cache_valid = false
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

function MangaLibraryWidget:openChapter(chapter, series_name)
    debugLog("Opening: " .. chapter.path)
    debugLog("Series: " .. series_name)
    
    if not self.manga_library.reading_progress[series_name].read_chapters then
        self.manga_library.reading_progress[series_name].read_chapters = {}
    end
    
    self.manga_library.reading_progress[series_name].read_chapters[chapter.path] = true
    self.manga_library.settings:saveSetting("reading_progress", self.manga_library.reading_progress)
    self.manga_library.settings:flush()
    
    UIManager:close(self)
    self.manga_library:show({series = series_name, path = chapter.path})
    
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
        local a_num = extractChapterNumber(a.name)
        local b_num = extractChapterNumber(b.name)
        if a_num == b_num then
            return a.name < b.name
        end
        return a_num < b_num
    end)
    
    if not self.reading_progress[series_name] then
        self.reading_progress[series_name] = {}
    end
    
    self.reading_progress[series_name].chapters = chapters
    self.reading_progress[series_name].folder_path = series_path
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
