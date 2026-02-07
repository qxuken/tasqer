--- Binary encoding utilities for packing and unpacking integers and strings.
--- All integers are encoded in Big Endian format.
--- @class EncodeModule
local M = {}

--- Helper: Pack integer n into specific number of bytes (Big Endian)
--- @param n integer The integer to pack
--- @param bytes integer Number of bytes to pack into (1, 2, 4, or 8)
--- @return string? data The packed binary string, or nil on error
--- @return string? err Error message if packing failed
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

--- Helper: Unpack integer from string at offset (Big Endian)
--- @param s string The binary string to unpack from
--- @param off integer? Starting offset (1-based, defaults to 1)
--- @param bytes integer Number of bytes to read (1, 2, 4, or 8)
--- @return integer? value The unpacked integer, or nil on error
--- @return integer next_off The next offset after reading
--- @return string? err Error message if unpacking failed
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

--- Pack an unsigned 8-bit integer (1 byte)
--- @param n integer The integer to pack (0-255)
--- @return string? data The packed byte, or nil on error
--- @return string? err Error message if packing failed
function M.u8(n)
	return pack_uint_be(n, 1)
end

--- Pack an unsigned 16-bit integer (2 bytes, Big Endian)
--- @param n integer The integer to pack (0-65535)
--- @return string? data The packed bytes, or nil on error
--- @return string? err Error message if packing failed
function M.u16(n)
	return pack_uint_be(n, 2)
end

--- Pack an unsigned 32-bit integer (4 bytes, Big Endian)
--- @param n integer The integer to pack (0-4294967295)
--- @return string? data The packed bytes, or nil on error
--- @return string? err Error message if packing failed
function M.u32(n)
	return pack_uint_be(n, 4)
end

--- Pack an unsigned 64-bit integer (8 bytes, Big Endian)
--- @param n integer The integer to pack
--- @return string? data The packed bytes, or nil on error
--- @return string? err Error message if packing failed
function M.u64(n)
	return pack_uint_be(n, 8)
end

-- Public Primitive Unpackers

--- Unpack an unsigned 8-bit integer (1 byte)
--- @param s string The binary string to unpack from
--- @param off integer? Starting offset (1-based, defaults to 1)
--- @return integer? value The unpacked integer, or nil on error
--- @return integer next_off The next offset after reading
--- @return string? err Error message if unpacking failed
function M.unpack_u8(s, off)
	return unpack_uint_be(s, off, 1)
end

--- Unpack an unsigned 16-bit integer (2 bytes, Big Endian)
--- @param s string The binary string to unpack from
--- @param off integer? Starting offset (1-based, defaults to 1)
--- @return integer? value The unpacked integer, or nil on error
--- @return integer next_off The next offset after reading
--- @return string? err Error message if unpacking failed
function M.unpack_u16(s, off)
	return unpack_uint_be(s, off, 2)
end

--- Unpack an unsigned 32-bit integer (4 bytes, Big Endian)
--- @param s string The binary string to unpack from
--- @param off integer? Starting offset (1-based, defaults to 1)
--- @return integer? value The unpacked integer, or nil on error
--- @return integer next_off The next offset after reading
--- @return string? err Error message if unpacking failed
function M.unpack_u32(s, off)
	return unpack_uint_be(s, off, 4)
end

--- Unpack an unsigned 64-bit integer (8 bytes, Big Endian)
--- @param s string The binary string to unpack from
--- @param off integer? Starting offset (1-based, defaults to 1)
--- @return integer? value The unpacked integer, or nil on error
--- @return integer next_off The next offset after reading
--- @return string? err Error message if unpacking failed
function M.unpack_u64(s, off)
	return unpack_uint_be(s, off, 8)
end

-- String Packers

--- Packs a string prefixed with a 2-byte (u16) length
--- @param str string The string to pack
--- @return string? data The length-prefixed packed string, or nil on error
--- @return string? err Error message if packing failed
function M.pack_str_u16(str)
	if type(str) ~= "string" then
		return nil, "value must be string"
	end
	if #str > 0xFFFF then
		return nil, "string too long"
	end
	return M.u16(#str) .. str
end

--- Unpacks a string prefixed with a 2-byte (u16) length
--- @param s string The binary string to unpack from
--- @param off integer? Starting offset (1-based, defaults to 1)
--- @return string? value The unpacked string, or nil on error
--- @return integer next_off The next offset after reading
--- @return string? err Error message if unpacking failed
function M.unpack_str_u16(s, off)
	local len
	len, off = M.unpack_u16(s, off)
	if #s - off + 1 < len then
		return nil, off, "not enough bytes for string body"
	end
	local val = s:sub(off, off + len - 1)
	return val, off + len, nil
end

--- Unpacks a raw fixed-length string (e.g. for Magic bytes)
--- @param s string The binary string to unpack from
--- @param off integer? Starting offset (1-based, defaults to 1)
--- @param len integer Number of bytes to read
--- @return string? value The unpacked raw bytes, or nil on error
--- @return integer next_off The next offset after reading
--- @return string? err Error message if unpacking failed
function M.unpack_raw(s, off, len)
	off = off or 1
	if #s - off + 1 < len then
		return nil, off, "not enough bytes for raw string"
	end
	return s:sub(off, off + len - 1), off + len, nil
end

return M
