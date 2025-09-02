local json = require ("dkjson")
local config = require("config")
local crypto = require("plc.aead_chacha_poly")


function on_open()
    local chn = c2.Channel.by_name("hemirt")
    chn:add_message(c2.Message.new({
        elements = {
            {
                type = "text",
                text = "open",
            }
        }
    }))
end

function on_close()
    local chn = c2.Channel.by_name("hemirt")
    chn:add_message(c2.Message.new({
        elements = {
            {
                type = "text",
                text = "close",
            }
        }
    }))
end

function on_text(data)
    local chn = c2.Channel.by_name("hemirt")
    local obj, pos, err = json.decode(data, 1, json.null)
    if err then
        return
    end

    obj.timestamp = math.floor(obj.timestamp / 1000) + config.timezone * 3600
    local seconds_in_day = 24 * 60 * 60
    local seconds_today = obj.timestamp % seconds_in_day
    local seconds = math.floor(seconds_today % 60)
    local hours = math.floor(seconds_today / 3600)
    local minutes = math.floor((seconds_today % 3600) / 60)
    local time_str = string.format("%02d:%02d:%02d", hours, minutes, seconds)

    chn:add_message(c2.Message.new({
        elements = {
            {
                type = "text",
                text = time_str .. " " .. obj.sender .. ": " .. obj.text,
            }
        }
    }))
    
end

c2.register_command("/open", function(ctx)
    if _G.socket ~= nil then
        _G.socket:close()
    end

    local headers = {Authorization = "Bearer mytoken"}

    _G.socket = c2.WebSocket.new(config.server_url, {headers = headers, on_open = on_open, on_close = on_close, on_text = on_text})
    local chn = c2.Channel.by_name("hemirt")
    chn:add_message(c2.Message.new({
        elements = {
            {
                type = "text",
                text = "data: " .. ctx.channel:get_name(),
            }
        }
    }))
end)


c2.register_command("/close", function(ctx)
    if _G.socket ~= nil then
        _G.socket:close()
    end
end)

function returnNilFromException(reason, value, state, defaultmessage)
  return nil
end

c2.register_command("/send", function(ctx)
    if _G.socket == nil then 
        return
    end
    table.remove(ctx.words, 1)
    local message = table.concat(ctx.words, " ")
    local jsonObj = {
        sender = "hemirt",
        text = message
    }
    local jsonString = json.encode(jsonObj, { exception = returnNilFromException })

    if jsonString == nil then
        return
    end

    _G.socket:send_text(jsonString)
    
end)


