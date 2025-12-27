local logger = require("lua.logger")
local frame = require("lua.message.frame")
local encode = require("lua.message.encode")

local M = {}

M.type = {
	-- purpose: Pings issued by client to check if leader is alive.
	-- from: @follower
	-- to: @leader
	ping = 0x01,
	-- purpose: Pin response from leader to follower.
	-- from: @leader
	-- to: @follower
	pong = 0x02,
	-- purpose: Request from outside world to execute task.
	-- from: any
	-- to: @leader
	task_request = 0x03,
	-- purpose: Request from leader to execute task.
	-- from: @leader
	-- to: @follower
	task_dispatch = 0x04,
	-- purpose: Follower confirms that it can execute task.
	-- from: @follower
	-- to: @leader
	task_capable = 0x05,
	-- purpose: Leader grants permission to complete the task.
	-- from: @leader
	-- to: @follower
	task_granted = 0x06,
	-- purpose: Leader denies permission to complete the task. Likely it was granted to other follower.
	-- from: @leader
	-- to: @follower
	task_denied = 0x07,
}
M.name = {}
for name, t in pairs(M.type) do
	M.name[t] = name
end
function M.get_name(message_type)
	if not message_type then
		return nil
	end
	local name = M.name[message_type]
	if not name then
		return message_type
	end
	return name
end

function M.pack_ping_frame(ts)
	return frame.pack(M.type.ping, encode.u64(ts))
end
function M.pack_pong_frame(ts)
	return frame.pack(M.type.pong, encode.u64(ts))
end
function M.pack_task_request_frame(id, type_id, data)
	return frame.pack(M.type.task_request, encode.u32(id) .. encode.u8(type_id) .. encode.pack_str_u16(data))
end
function M.pack_task_dispatch_frame(id, type_id, data)
	return frame.pack(M.type.task_dispatch, encode.u32(id) .. encode.u8(type_id) .. encode.pack_str_u16(data))
end
function M.pack_task_capable_frame(id)
	return frame.pack(M.type.task_capable, encode.u32(id))
end
function M.pack_task_granted_frame(id)
	return frame.pack(M.type.task_granted, encode.u32(id))
end
function M.pack_task_denied_frame(id)
	return frame.pack(M.type.task_denied, encode.u32(id))
end

function M.unpack_frame(buf)
	local msg_type, payload, err = frame.unpack(buf)
	if err then
		return nil, nil, err
	end
	local data = {}
	if msg_type == M.type.ping or msg_type == M.type.pong then
		data.ts, _, err = encode.unpack_u64(payload, 1)
	elseif msg_type == M.type.task_dispatch or msg_type == M.type.task_request then
		local off
		data.id, off, err = encode.unpack_u32(payload, 1)
		if err ~= nil then
			return nil, nil, err
		end
		data.type_id, off, err = encode.unpack_u8(payload, off)
		if err ~= nil then
			return nil, nil, err
		end
		data.data, off, err = encode.unpack_str_u16(payload, off)
		if err ~= nil then
			return nil, nil, err
		end
	elseif msg_type == M.type.task_capable or msg_type == M.type.task_granted or msg_type == M.type.task_denied then
		data.id, _, err = encode.unpack_u32(payload, 1)
	else
		return nil, nil, "unknown cmd_id=" .. msg_type
	end
	if err ~= nil then
		return nil, nil, err
	end
	return msg_type, data, nil
end

function M.debug_log_cmd(cmd_id, payload)
	logger.debug("cmd = " .. M.get_name(cmd_id))
	logger.debug_dump(payload)
	logger.debug("---")
end

return M
