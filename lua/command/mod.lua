local logger = require("lua.logger")
local frame = require("lua.command.frame")
local encode = require("lua.command.encode")

local M = {}

M.id = {
	-- purpose: Pings issued by client to check if leader is alive.
	-- from: @follower
	-- to: @leader
	ping = 0x01,
	-- purpose: Pin response from leader to follower.
	-- from: @leader
	-- to: @follower
	pong = 0x02,
	-- purpose: Request from outside world to open file.
	-- from: any
	-- to: @leader
	open_request = 0x03,
	-- purpose: Request from leader to open file.
	-- from: @leader
	-- to: @follower
	open_task = 0x04,
	-- purpose: Follower confirms that it can open file.
	-- from: @follower
	-- to: @leader
	open_possible = 0x05,
	-- purpose: Leader grants permission to complete the task.
	-- from: @leader
	-- to: @follower
	open_granted = 0x06,
	-- purpose: Leader denies permission to complete the task. Likely it was granted to other follower.
	-- from: @leader
	-- to: @follower
	open_denied = 0x07,
}
M.name = {}
for name, id in pairs(M.id) do
	M.name[id] = name
end
function M.get_name(id)
	if not id then
		return nil
	end
	local name = M.name[id]
	if not name then
		return id
	end
	return name
end

function M.pack_ping_frame(ts)
	return frame.pack(M.id.ping, encode.u64(ts))
end
function M.pack_pong_frame(ts)
	return frame.pack(M.id.pong, encode.u64(ts))
end
function M.pack_open_request_frame(id, path, line, col)
	return frame.pack(
		M.id.open_request,
		encode.u32(id) .. encode.pack_str_u16(path) .. encode.u32(line or 1) .. encode.u32(col or 1)
	)
end
function M.pack_open_task_frame(id, path, line, col)
	return frame.pack(
		M.id.open_task,
		encode.u32(id) .. encode.pack_str_u16(path) .. encode.u32(line or 1) .. encode.u32(col or 1)
	)
end
function M.pack_open_possible_frame(id)
	return frame.pack(M.id.open_possible, encode.u32(id))
end
function M.pack_open_granted_frame(id)
	return frame.pack(M.id.open_granted, encode.u32(id))
end
function M.pack_open_denied_frame(id)
	return frame.pack(M.id.open_denied, encode.u32(id))
end

function M.unpack_frame(buf)
	local cmd_id, payload, err = frame.unpack(buf)
	if err then
		return nil, nil, err
	end
	local data = {}
	if cmd_id == M.id.ping or cmd_id == M.id.pong then
		data.ts, _, err = encode.unpack_u64(payload, 1)
	elseif cmd_id == M.id.open_task or cmd_id == M.id.open_request then
		local off
		data.id, off, err = encode.unpack_u32(payload, 1)
		if err ~= nil then
			return nil, nil, err
		end
		data.path, off, err = encode.unpack_str_u16(payload, off)
		if err ~= nil then
			return nil, nil, err
		end
		data.line, off, err = encode.unpack_u32(payload, off)
		if err ~= nil then
			return nil, nil, err
		end
		data.col, off, err = encode.unpack_u32(payload, off)
		if err ~= nil then
			return nil, nil, err
		end
	elseif cmd_id == M.id.open_possible or cmd_id == M.id.open_granted or cmd_id == M.id.open_denied then
		data.id, _, err = encode.unpack_u32(payload, 1)
	else
		return nil, nil, "unknown cmd_id=" .. cmd_id
	end
	if err ~= nil then
		return nil, nil, err
	end
	return cmd_id, data, nil
end

function M.debug_log_cmd(cmd_id, payload)
	logger.debug("cmd = " .. M.get_name(cmd_id))
	logger.debug_dump(payload)
	logger.debug("---")
end

return M
