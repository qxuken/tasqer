local M = {}

-- Helper: Pack integer n into specific number of bytes (Big Endian)
local function pack_uint_be(n, bytes)
	if type(n) ~= "number" then
		return nil, "n must be a number"
	end
	if n % 1 ~= 0 then
		return nil, "n must be an integer"
	end
	if n < 0 then
		return nil, "n must be non-negative"
	end

	local t = {}
	for i = bytes, 1, -1 do
		t[i] = string.char(n % 256)
		n = math.floor(n / 256)
	end
	-- Note: roughly > 2^53 in Lua 5.1 (doubles) loses precision
	if n ~= 0 then
		return nil, "value does not fit in " .. bytes .. " bytes"
	end
	return table.concat(t), nil
end

-- Helper: Unpack integer from string at offset (Big Endian)
local function unpack_uint_be(s, off, bytes)
	off = off or 1
	if #s - off + 1 < bytes then
		return nil, off, "not enough bytes to unpack integer"
	end
	local n = 0
	for i = 0, bytes - 1 do
		n = n * 256 + s:byte(off + i)
	end
	return n, off + bytes, nil
end

-- Public Primitive Packers

function M.u8(n)
	return pack_uint_be(n, 1)
end
function M.u16(n)
	return pack_uint_be(n, 2)
end
function M.u32(n)
	return pack_uint_be(n, 4)
end
function M.u64(n)
	return pack_uint_be(n, 8)
end

-- Public Primitive Unpackers

function M.unpack_u8(s, off)
	return unpack_uint_be(s, off, 1)
end
function M.unpack_u16(s, off)
	return unpack_uint_be(s, off, 2)
end
function M.unpack_u32(s, off)
	return unpack_uint_be(s, off, 4)
end
function M.unpack_u64(s, off)
	return unpack_uint_be(s, off, 8)
end

-- String Packers

-- Packs a string prefixed with a 2-byte (u16) length
function M.pack_str_u16(str)
	if type(str) ~= "string" then
		return nil, "value must be string"
	end
	if #str > 0xFFFF then
		return nil, "string too long"
	end
	return M.u16(#str) .. str
end

-- Unpacks a string prefixed with a 2-byte (u16) length
function M.unpack_str_u16(s, off)
	local len
	len, off = M.unpack_u16(s, off)
	if #s - off + 1 < len then
		return nil, off, "not enough bytes for string body"
	end
	local val = s:sub(off, off + len - 1)
	return val, off + len, nil
end

-- Unpacks a raw fixed-length string (e.g. for Magic bytes)
function M.unpack_raw(s, off, len)
	off = off or 1
	if #s - off + 1 < len then
		return nil, off, "not enough bytes for raw string"
	end
	return s:sub(off, off + len - 1), off + len, nil
end

return M
