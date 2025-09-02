local json = require('dkjson')
local file = io.open("config.ini", "r")
local content = file:read("*a")

local config, pos, err = json.decode(content, 1, json.null)

file:close()

if err then
    error("invalid config")
end

return config