-- Copyright (c) 2015  Phil Leblanc  -- see LICENSE file
-- Modifications (c) 2025 hemirt, All Rights Reserved -- see LICENSE file
------------------------------------------------------------
--[[

aead_chacha_poly

Authenticated Encryption with Associated Data (AEAD) [1], based
on Chacha20 stream encryption and Poly1305 MAC, as defined
in RFC 7539 [2].

[1] https://en.wikipedia.org/wiki/Authenticated_encryption
[2] http://www.rfc-editor.org/rfc/rfc7539.txt

This file uses chacha20.lua and poly1305 for the encryption
and MAC primitives.

]]

local chacha20 = require "plc.chacha20"
local poly1305 = require "plc.poly1305"
local base64 = require "plc.base64"
local sha = require "plc.sha2"

local counter = 1337

local function random_bytes(n)
    local s = {}
    for i = 1, n do
        s[i] = string.char(math.random(0, 255))
    end
    return table.concat(s)
end

------------------------------------------------------------
-- poly1305 key generation

local poly_keygen = function(key, nonce)
	local m = string.rep('\0', 64)
	local e = chacha20.xchacha20_encrypt(key, 0, nonce, m) -- counter 0
	-- keep only first the 256 bits (32 bytes)
	return e:sub(1, 32)
end

local generate_per_message_key = function(group_key, room_name)
	counter = counter + 1
	local salt = random_bytes(32) .. room_name .. tostring(counter) .. "key"
	return sha.sha256(group_key .. salt), salt
end

local generate_per_message_key_from_salt = function(group_key, salt)
	return sha.sha256(group_key .. salt)
end

local generate_per_message_nonce = function(group_key, room_name)
	counter = counter + 1
    local salt = random_bytes(32) .. room_name .. tostring(counter) .. "nonce"
    local full_hash = sha.sha256(salt)
    return full_hash:sub(1,24)
end


local pad16 = function(s)
	-- return null bytes to add to s so that #s is a multiple of 16
	return (#s % 16 == 0) and "" or ('\0'):rep(16 - (#s % 16))
end

local app = table.insert

local encrypt = function(aad, group_key, room_name, plain)
	-- aad: additional authenticated data - arbitrary length
	-- key: 32-byte string
	-- (memory inefficient - encr text is copied in mac_data)

	local key, key_salt = generate_per_message_key(group_key, room_name)
	local nonce = generate_per_message_nonce(group_key, room_name)
	local mt = {} -- mac_data table
	local otk = poly_keygen(key, nonce) -- counter 0
	local encr = chacha20.xchacha20_encrypt(key, 1, nonce, plain) -- counter 1
	app(mt, aad)
	app(mt, pad16(aad))
	app(mt, encr)
	app(mt, pad16(encr))
	-- aad and encrypted text length must be encoded as
	-- little endian _u64_ (and not u32) -- see errata at
	-- https://www.rfc-editor.org/errata_search.php?rfc=7539
	app(mt, string.pack('<I8', #aad))
	app(mt, string.pack('<I8', #encr))
	local mac_data = table.concat(mt)
--~ 	p16('mac', mac_data)
	local tag = poly1305.auth(mac_data, otk)
	return {
		aad = base64.encode(aad),
		nonce = base64.encode(nonce),
		key_salt = base64.encode(key_salt),
		ciphertext = base64.encode(encr),
		tag = base64.encode(tag)
	}
end --xchacha20_aead_encrypt()

local function decrypt(group_key, room_name, packet)
	-- (memory inefficient - encr text is copied in mac_data)
	-- (structure similar to aead_encrypt => what could be factored?)
	local mt = {} -- mac_data table
	local aad = base64.decode(packet.aad)
	local nonce = base64.decode(packet.nonce)
	local key_salt = base64.decode(packet.key_salt)
	local key = generate_per_message_key_from_salt(group_key, key_salt)
	local tag = base64.decode(packet.tag)
	local encr = base64.decode(packet.ciphertext)
	if #nonce ~= 24 then
		return nil, "invalid nonce"
	end
	local otk = poly_keygen(key, nonce) -- counter 0
	app(mt, aad)
	app(mt, pad16(aad))
	app(mt, encr)
	app(mt, pad16(encr))
	app(mt, string.pack('<I8', #aad))
	app(mt, string.pack('<I8', #encr))
	local mac_data = table.concat(mt)
	local mac = poly1305.auth(mac_data, otk)
	if mac == tag then
		local plain = chacha20.xchacha20_decrypt(key, 1, nonce, encr) -- counter 1
		return plain, ""
	else
		return nil, "auth failed"
	end
end -- xchacha20_aead_decrypt()


------------------------------------------------------------
-- return aead_chacha_poly module

return {
	poly_keygen = poly_keygen,
	encrypt = encrypt,
	decrypt = decrypt,
	}
