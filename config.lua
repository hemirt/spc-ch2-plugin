local json = require('dkjson')
local file = io.open("config.json", "r")
local content = file:read("*a")

local config, pos, err = json.decode(content, 1, json.null)

file:close()

if err then
    error("invalid config")
end

config.ping_interval = config.ping_interval * 1000

return config