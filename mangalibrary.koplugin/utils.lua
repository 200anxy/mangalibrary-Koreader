
local Utils = {}

function Utils:extractChapterNumber(str)
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

return Utils