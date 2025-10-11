local logger = require("logger")

local Logger = {}

local time = os.date("%H:%M:%S")

function Logger.debug(msg)
    logger.info("[" .. time .. "] MangaLibrary: " .. msg)
end


return Logger
