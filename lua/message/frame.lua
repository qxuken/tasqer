local logger = require("lua.logger")
local encode = require("lua.message.encode")

-- Protocol constants
local MAGIC = "EO_QMGC25"
local MAGIC_LEN = #MAGIC
local VERSION = 1
local VERSION_ENC = encode.u8(VERSION)

-- Minimum bytes needed to parse the fixed header:
-- MAGIC(9) | VERSION(u8) | MESSAGE_TYPE(u8) | LENGTH(u16)
local MIN_FRAME = MAGIC_LEN + 1 + 1 + 2

local M = {}

-- Build a frame: MAGIC | VERSION(u8) | MESSAGE_TYPE(u8) | LENGTH(u16 BE) | DATA
function M.pack(msg_type, data)
	assert(type(msg_type) == "number", "command must be an integer")
	assert(type(data) == "string", "data must be a string")
	if #data > 0xFFFF then
		error("data too long for u16 length field")
	end
	return table.concat({
		MAGIC,
		VERSION_ENC,
		encode.u8(msg_type),
		encode.u16(#data),
		data,
	})
end

-- Parse a frame; returns: message_type, data, err
function M.unpack(buf, off)
	off = off or 1
	if type(buf) ~= "string" then
		return 0, nil, "frame must be a string"
	end

	local msg_len = #buf
	if msg_len < MIN_FRAME then
		return 0, nil, "truncated header"
	end

	local magic, version, msg_type, data_len, err

	-- Decode Header
	magic, off, err = encode.unpack_raw(buf, off, MAGIC_LEN)
	if err ~= nil then
		return 0, nil, err
	end
	if magic ~= MAGIC then
		return 0, nil, "bad magic"
	end

	version, off, err = encode.unpack_u8(buf, off)
	if err ~= nil then
		return 0, nil, err
	end
	if version ~= VERSION then
		return 0, nil, "unsupported version " .. tostring(version)
	end

	msg_type, off, err = encode.unpack_u8(buf, off)
	if err ~= nil then
		return 0, nil, err
	end

	data_len, off, err = encode.unpack_u16(buf, off)
	if err ~= nil then
		return 0, nil, err
	end

	-- Check Payload availability
	local data_start = off
	local data_end = data_start + data_len - 1

	if data_end > msg_len then
		return 0, nil, "payload length exceeds message size"
	end

	local data = buf:sub(data_start, data_end)
	local next_offset = data_end + 1

	if next_offset <= msg_len then
		logger.warn("message was not fully consumed. msg_len=" .. msg_len .. " next_offset=" .. next_offset)
	end

	return msg_type, data, nil
end

return M
