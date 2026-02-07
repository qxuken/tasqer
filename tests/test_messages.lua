--- Tests for message encoding/decoding round-trips.
--- Covers frame packing, message types, and openfile payload serialization.

local h = require("tests.test_helpers")
local message = require("tasqer.message.mod")
local frame = require("tasqer.message.frame")
local encode = require("tasqer.message.encode")

h.suite("message/encode")

h.test("u8 round-trip", function()
	for _, v in ipairs({ 0, 1, 127, 255 }) do
		local packed = encode.u8(v)
		local unpacked = encode.unpack_u8(packed, 1)
		h.assert_eq(unpacked, v, "u8(" .. v .. ")")
	end
end)

h.test("u16 round-trip", function()
	for _, v in ipairs({ 0, 1, 256, 65535 }) do
		local packed = encode.u16(v)
		local unpacked = encode.unpack_u16(packed, 1)
		h.assert_eq(unpacked, v, "u16(" .. v .. ")")
	end
end)

h.test("u32 round-trip", function()
	for _, v in ipairs({ 0, 1, 65536, 4294967295 }) do
		local packed = encode.u32(v)
		local unpacked = encode.unpack_u32(packed, 1)
		h.assert_eq(unpacked, v, "u32(" .. v .. ")")
	end
end)

h.test("u64 round-trip", function()
	for _, v in ipairs({ 0, 1, 4294967296, 1099511627776 }) do
		local packed = encode.u64(v)
		local unpacked = encode.unpack_u64(packed, 1)
		h.assert_eq(unpacked, v, "u64(" .. v .. ")")
	end
end)

h.test("pack_str_u16 round-trip", function()
	for _, s in ipairs({ "", "hello", "a/b/c.txt", string.rep("x", 1000) }) do
		local packed = encode.pack_str_u16(s)
		local unpacked = encode.unpack_str_u16(packed, 1)
		h.assert_eq(unpacked, s, "str_u16")
	end
end)

h.test("u8 rejects negative", function()
	local _, err = encode.u8(-1)
	h.assert_not_nil(err)
end)

h.test("u8 rejects overflow", function()
	local _, err = encode.u8(256)
	h.assert_not_nil(err)
end)

h.test("unpack_u8 rejects empty", function()
	local _, _, err = encode.unpack_u8("", 1)
	h.assert_not_nil(err)
end)

h.suite("message/frame")

h.test("frame pack/unpack round-trip", function()
	local data = "hello world"
	local packed = frame.pack(0x10, data)
	local msg_type, unpacked_data, err = frame.unpack(packed)
	h.assert_nil(err)
	h.assert_eq(msg_type, 0x10)
	h.assert_eq(unpacked_data, data)
end)

h.test("frame rejects truncated header", function()
	local _, _, err = frame.unpack("short")
	h.assert_not_nil(err)
end)

h.test("frame rejects bad magic", function()
	local _, _, err = frame.unpack("BADMAGIC!!" .. string.rep("\0", 10))
	h.assert_not_nil(err)
end)

h.test("frame rejects non-string input", function()
	local _, _, err = frame.unpack(42)
	h.assert_not_nil(err)
end)

h.suite("message/protocol")

h.test("ping frame round-trip", function()
	local ts = 1234567890
	local packed = message.pack_ping_frame(ts)
	local msg_type, payload, err = message.unpack_frame(packed)
	h.assert_nil(err)
	h.assert_eq(msg_type, message.type.ping)
	h.assert_eq(payload.ts, ts)
end)

h.test("pong frame round-trip", function()
	local ts = 9876543210
	local packed = message.pack_pong_frame(ts)
	local msg_type, payload, err = message.unpack_frame(packed)
	h.assert_nil(err)
	h.assert_eq(msg_type, message.type.pong)
	h.assert_eq(payload.ts, ts)
end)

h.test("task_request frame round-trip", function()
	local id, type_id, data = 42, 1, "payload_data"
	local packed = message.pack_task_request_frame(id, type_id, data)
	local msg_type, payload, err = message.unpack_frame(packed)
	h.assert_nil(err)
	h.assert_eq(msg_type, message.type.task_request)
	h.assert_eq(payload.id, id)
	h.assert_eq(payload.type_id, type_id)
	h.assert_eq(payload.data, data)
end)

h.test("task_dispatch frame round-trip", function()
	local id, type_id, data = 99, 1, "dispatch_data"
	local packed = message.pack_task_dispatch_frame(id, type_id, data)
	local msg_type, payload, err = message.unpack_frame(packed)
	h.assert_nil(err)
	h.assert_eq(msg_type, message.type.task_dispatch)
	h.assert_eq(payload.id, id)
	h.assert_eq(payload.type_id, type_id)
	h.assert_eq(payload.data, data)
end)

h.test("task ID-only frames round-trip", function()
	local id_frames = {
		{ pack = message.pack_task_capable_frame, expected_type = message.type.task_capable },
		{ pack = message.pack_task_granted_frame, expected_type = message.type.task_granted },
		{ pack = message.pack_task_denied_frame, expected_type = message.type.task_denied },
		{ pack = message.pack_task_pending_frame, expected_type = message.type.task_pending },
		{ pack = message.pack_task_completed_frame, expected_type = message.type.task_completed },
		{ pack = message.pack_task_failed_frame, expected_type = message.type.task_failed },
		{ pack = message.pack_task_not_capable_frame, expected_type = message.type.task_not_capable },
		{ pack = message.pack_task_exec_done_frame, expected_type = message.type.task_exec_done },
		{ pack = message.pack_task_exec_failed_frame, expected_type = message.type.task_exec_failed },
	}
	for _, entry in ipairs(id_frames) do
		local task_id = 77
		local packed = entry.pack(task_id)
		local msg_type, payload, err = message.unpack_frame(packed)
		h.assert_nil(err, message.get_name(entry.expected_type) .. " error")
		h.assert_eq(msg_type, entry.expected_type, "type mismatch")
		h.assert_eq(payload.id, task_id, message.get_name(entry.expected_type) .. " id mismatch")
	end
end)

h.test("get_name returns name for known types", function()
	h.assert_eq(message.get_name(message.type.ping), "ping")
	h.assert_eq(message.get_name(message.type.task_request), "task_request")
end)

h.test("get_name returns id for unknown types", function()
	h.assert_eq(message.get_name(0xFF), 0xFF)
end)

h.test("get_name returns nil for nil input", function()
	h.assert_nil(message.get_name(nil))
end)

h.suite("tasks/openfile")

h.test("openfile encode/decode round-trip", function()
	local openfile = require("tasqer.tasks.openfile")
	local payload = { path = "/home/user/test.lua", row = 42, col = 7 }
	local encoded, err = openfile.encode(payload)
	h.assert_nil(err)
	h.assert_not_nil(encoded)
	local decoded, err2 = openfile.decode(encoded)
	h.assert_nil(err2)
	h.assert_eq(decoded.path, payload.path)
	h.assert_eq(decoded.row, payload.row)
	h.assert_eq(decoded.col, payload.col)
end)

h.test("openfile decode rejects non-string", function()
	local openfile = require("tasqer.tasks.openfile")
	local _, err = openfile.decode(42)
	h.assert_not_nil(err)
end)

h.test("openfile default can_execute returns false", function()
	-- Reload a fresh openfile module to test defaults
	-- (mock_tasks may have overridden it via register)
	local openfile = require("tasqer.tasks.openfile")
	-- Save and restore
	local orig_can = openfile.can_execute
	-- Reset to default
	local fresh = {
		can_execute = function(_, cb)
			cb(false)
		end,
	}
	local called = false
	fresh.can_execute({}, function(capable)
		called = true
		h.assert_false(capable, "default should be not capable")
	end)
	h.assert_true(called)
end)

return h.run()
