local json = require ("dkjson")
local config = require("config")
local crypto = require("plc.aead_chacha_poly")
local base64 = require("plc.base64")
local sha = require("plc.sha2")

local channels = {}

for k,channel in pairs(config.channels) do
    channels[channel.local_chatterino_split] = channel
    channel.ws = nil
    channel.ping_in_flight = false
    channel.secret_key = sha.sha256(channel.secret_key)
    channel.try_connect = true
end

function returnNilFromException(reason, value, state, defaultmessage)
    return nil
end

function on_open(channel)
    local chn = c2.Channel.by_name(channel.local_chatterino_split)
    if chn then
        chn:add_system_message("Connected to remote room: " .. channel.remote_server_room)
    end
end

function connect(channel)
    if channel.try_connect == false then
        return
    end
    local chn = c2.Channel.by_name(channel.local_chatterino_split)
    if chn == nil then
        return
    end
    chn:add_system_message("Connecting to remote room: " .. channel.remote_server_room)
    local headers = {Authorization = config.server_password, room = channel.remote_server_room}
    channel.ws = c2.WebSocket.new(config.server_url, {headers = headers, on_open = make_on_open(channel), on_close = make_on_close(channel), on_text = make_on_text(channel) })
end

function disconnect(channel)
    channel.ping_in_flight = false
    if channel.ws == nil then
        return
    end
    local chn = c2.Channel.by_name(channel.local_chatterino_split)
    if chn then
        chn:add_system_message("Disconnecting from remote room: " .. channel.remote_server_room)
    end
    channel.ws:close()
    channel.ws = nil
end

function reconnect(channel)
    if channel.try_connect == false then
        return
    end

    local chn = c2.Channel.by_name(channel.local_chatterino_split)
    if chn then
        chn:add_system_message("Reconnecting to remote server room: " .. channel.remote_server_room)
    end

    if channel.ws ~= nil then
        channel.ping_in_flight = false
        channel.ws:close()
        channel.ws = nil
    end
    connect(channel)
end

function make_try_reconnect(channel)
    return function()
        reconnect(channel)
    end
end

function on_close(channel)
    local chn = c2.Channel.by_name(channel.local_chatterino_split)
    if chn then
        chn:add_system_message("Disconnected from remote room: " .. channel.remote_server_room)
        local try_reconnect = make_try_reconnect(channel)
        c2.later(try_reconnect, 3000) 
    end
end

function on_text(channel, data)
    local chn = c2.Channel.by_name(channel.local_chatterino_split)
    if chn == nil then
        return
    end
    
    local sentence, pos, err = json.decode(data, 1, json.null)
    if err then
        return
    end
    if sentence.type == "pong" then
        channel.ping_in_flight = false
        return
    end
    
    if sentence.type ~= "message" then
        print("Received not message")
        return
    end

    local message = sentence.data
    local packet, pos, err = json.decode(message.packet, 1, json.null)
    if err then
        print("Packet not decodable json")
        return
    end

    message.timestamp = math.floor(message.timestamp / 1000) + config.timezone * 3600
    local seconds_in_day = 24 * 60 * 60
    local seconds_today = message.timestamp % seconds_in_day
    local seconds = math.floor(seconds_today % 60)
    local hours = math.floor(seconds_today / 3600)
    local minutes = math.floor((seconds_today % 3600) / 60)
    local time_str = string.format("%02d:%02d:%02d", hours, minutes, seconds)

    local plain, err = crypto.decrypt(channel.secret_key, channel.remote_server_room, packet)

    if (plain) then
        local obj, pos, err = json.decode(plain, 1, json.null)
        if (err) then
            print("Final message not decodable json")
            return
        end

        local aadB64 = base64.decode(packet.aad)
        local aad, pos, err = json.decode(aadB64, 1, json.null)
        if (err) then
            print("AAD not decodable json")
            return
        end

        chn:add_message(c2.Message.new({
            id = message.uuid,
            elements = {
                {
                    type = "text",
                    color = "#868d8d8d",
                    text = time_str .. " [#" ..  aad.room .. "] "
                },
                {
                    type = "text",
                    color = "#ff398a7f",
                    text = obj.sender .. ": "
                },
                {
                    type = "text",
                    text = obj.text
                }
            }
        }))
    else
        chn:add_message(c2.Message.new({
            id = message.uuid,
            elements = {
                {
                    type = "text",
                    color = "#AAe58686",
                    text = time_str .. " unable to decrypt message",
                }
            }
        }))
    end
end

function make_on_open(channel)
    return function()
        on_open(channel)
    end
end

function make_on_close(channel)
    return function()
        on_close(channel)
    end
end

function make_on_text(channel)
    return function(data)
        on_text(channel, data)
    end
end

function send_ping(channel)
    if channel.ws == nil then
        return
    end
    channel.ping_in_flight = true
    local sentence = {
        type = "ping"
    }
    
    local jsonToSend = json.encode(sentence, { exception = returnNilFromException })
    if jsonToSend == nil then
        local chn = c2.Channel.by_name(channel.local_chatterino_split)
        if chn then
            chn:add_system_message("Unable to send ping to remote server room: " .. channel.remote_server_room)
        end
        return
    end

    channel.ws:send_text(jsonToSend)
end

function periodic_ping()
    for k,v in pairs(channels) do
        if v.ws == nil then
            if v.try_connect == true then
                local chn = c2.Channel.by_name(v.local_chatterino_split)
                if chn then
                    connect(v)
                end
            end
        else
            local chn = c2.Channel.by_name(v.local_chatterino_split)
            if chn == nil then
                disconnect(v)
                return
            end

            if v.ping_in_flight == true then
                v.ping_in_flight = false
                reconnect(v)
            else
                send_ping(v)
            end
        end
    end
    c2.later(periodic_ping, config.ping_interval)
end

c2.later(periodic_ping, 5000)

c2.register_command("/open", function(ctx)
    for k,v in pairs(channels) do
        v.try_connect = true;
        connect(v)
    end
end)


c2.register_command("/close", function(ctx)
    for k,v in pairs(channels) do
        v.try_connect = false;
        disconnect(v)
    end 
end)

c2.register_command("/send", function(ctx)
    local channel = channels[ctx.channel:get_name()]
    if (channel == nil or channel.ws == nil) then
        return
    end
    
    table.remove(ctx.words, 1)
    local message = table.concat(ctx.words, " ")
    local jsonObj = {
        sender = config.user_name,
        text = message
    }
    local jsonString = json.encode(jsonObj, { exception = returnNilFromException })
    if jsonString == nil then
        return
    end

    local aadObj = {
        room = channel.remote_server_room
    }
    local jsonAad = json.encode(aadObj, { exception = returnNilFromException })
    if jsonAad == nil then
        return
    end

    local packet = crypto.encrypt(jsonAad, channel.secret_key, channel.remote_server_room, jsonString)
    local sentence = {
        type = "message",
        data = packet
    }
    local jsonToSend = json.encode(sentence, { exception = returnNilFromException })
    if jsonToSend == nil then
        return
    end

    channels[ctx.channel:get_name()].ws:send_text(jsonToSend)
end)


