local logger = require("logger")

local Logger = {}

function Logger:debug(msg)
    logger.debug("[" .. os.date("%H:%M:%S") .. "] MangaLibrary: " .. msg)
end


return Logger
