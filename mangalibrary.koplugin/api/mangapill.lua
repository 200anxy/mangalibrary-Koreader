local http = require("socket.http")
local ltn12 = require("ltn12")

local Utils = require("utils")
local Logger = require("logger_module")

local MangaPillAPI = {
    _base_url = "https://mangapill.com",
}

function MangaPillAPI:makeRequest(path)
    local url = self._base_url .. path
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
    Logger.debug("HTTP request failed: " .. tostring(status_code))
    return nil
end

function MangaPillAPI:search(query)
    Logger.debug("Searching for: " .. query)
    local encoded = query:gsub(" ", "+")
    local html = self:makeRequest("/search?q=" .. encoded)
    if not html then 
        Logger.debug("Search request failed")
        return {} 
    end
    
    local results = {}
    
    for url, title in html:gmatch('<a%s+href="(/manga/[^"]+)"[^>]*>.-<div[^>]*>([^<]+)</div>') do
        local id = url:match("/manga/([^/]+)")
        if id then
            table.insert(results, {
                id = id,
                title = title:gsub("^%s*(.-)%s*$", "%1"),
                url = self._base_url .. url,
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
                    url = self._base_url .. url,
                })
                if #results >= 15 then break end
            end
        end
    end

    Logger.debug("Found " .. tostring(#results) .. " results")
    return results
end

function MangaPillAPI:getChapterList(manga_id)
    Logger.debug("Fetching chapters for: " .. manga_id)
    local html = self:makeRequest("/manga/" .. manga_id)
    if not html then 
        Logger.debug("Failed to get HTML")
        return {} 
    end
    
    local chapters = {}
    
    for url, title in html:gmatch('<a[^>]+href="(/chapters/[^"]+)"[^>]*>%s*([^<]+)%s*</a>') do
        local ch_num = Utils.extractChapterNumber(title)
        table.insert(chapters, {
            title = title:gsub("^%s*(.-)%s*$", "%1"),
            url = self._base_url .. url,
            chapter_id = url:match("/chapters/([^/]+)"),
            chapter_num = ch_num,
        })
    end
    
    if #chapters == 0 then
        for url, title in html:gmatch('data%-href="(/chapters/[^"]+)"[^>]*>%s*<[^>]+>([^<]+)</') do
            local ch_num = Utils.extractChapterNumber(title)
            table.insert(chapters, {
                title = title:gsub("^%s*(.-)%s*$", "%1"),
                url = self._base_url .. url,
                chapter_id = url:match("/chapters/([^/]+)"),
                chapter_num = ch_num,
            })
        end
    end
    
    if #chapters == 0 then
        for title, url in html:gmatch('<div[^>]*>([^<]+)</div>%s*<a[^>]+href="(/chapters/[^"]+)"') do
            local ch_num = Utils.extractChapterNumber(title)
            table.insert(chapters, {
                title = title:gsub("^%s*(.-)%s*$", "%1"),
                url = self._base_url .. url,
                chapter_id = url:match("/chapters/([^/]+)"),
                chapter_num = ch_num,
            })
        end
    end
    
    if #chapters == 0 then
        for url in html:gmatch('href="(/chapters/[^"]+)"') do
            local chapter_id = url:match("/chapters/([^/]+)")
            if chapter_id then
                local ch_num = Utils.extractChapterNumber(chapter_id)
                table.insert(chapters, {
                    title = "Chapter " .. chapter_id,
                    url = self._base_url .. url,
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
    
    Logger.debug("Sorted " .. tostring(#chapters) .. " chapters")
    return chapters
end

function MangaPillAPI:getChapterImages(chapter_url)
    local path = chapter_url:gsub(self._base_url, "")
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

return MangaPillAPI