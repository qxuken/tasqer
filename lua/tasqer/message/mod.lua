--- Message protocol module for packing and unpacking application-level messages.
--- Handles message types for leader-follower communication and task dispatching.
--- @class MessageModule

local logger = require("tasqer.logger")
local frame = require("tasqer.message.frame")
local encode = require("tasqer.message.encode")

--- @class MessageModule
local M = {}

--- Message type constants
--- @enum MessageType
M.type = {
	-- === Heartbeat (0x01-0x0F) ===
	-- purpose: Pings issued by client to check if leader is alive.
	-- from: @follower
	-- to: @leader
	ping = 0x01,
	-- purpose: Ping response from leader to follower.
	-- from: @leader
	-- to: @follower
	pong = 0x02,

	-- === Task Request Flow (0x10-0x1F) ===
	-- purpose: Request from outside world to execute task.
	-- from: any
	-- to: @leader
	task_request = 0x10,
	-- purpose: Acknowledgement that task was received and assigned an ID.
	-- from: @leader
	-- to: @requester
	task_pending = 0x11,
	-- purpose: Task finished successfully.
	-- from: @leader
	-- to: @requester
	task_completed = 0x12,
	-- purpose: Task failed (timeout, no capable instances, etc.).
	-- from: @leader
	-- to: @requester
	task_failed = 0x13,

	-- === Task Dispatch Flow (0x20-0x2F) ===
	-- purpose: Request from leader to execute task.
	-- from: @leader
	-- to: @follower
	task_dispatch = 0x20,
	-- purpose: Follower confirms that it can execute task.
	-- from: @follower
	-- to: @leader
	task_capable = 0x21,
	-- purpose: Follower reports that it cannot execute task.
	-- from: @follower
	-- to: @leader
	task_not_capable = 0x22,
	-- purpose: Leader grants permission to complete the task.
	-- from: @leader
	-- to: @follower
	task_granted = 0x23,
	-- purpose: Leader denies permission to complete the task. Likely it was granted to other follower.
	-- from: @leader
	-- to: @follower
	task_denied = 0x24,
	-- purpose: Follower reports task executed successfully.
	-- from: @follower
	-- to: @leader
	task_exec_done = 0x25,
	-- purpose: Follower reports task execution failed.
	-- from: @follower
	-- to: @leader
	task_exec_failed = 0x26,
}

--- Reverse lookup table: message type ID -> name
--- @type table<integer, string>
M.name = {}
for name, t in pairs(M.type) do
	M.name[t] = name
end

--- Get the name of a message type by its ID
--- @param message_type integer? The message type ID
--- @return string|integer|nil name The message type name, ID if unknown, or nil
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

--- Pack a ping frame with timestamp
--- @param ts integer Timestamp in milliseconds
--- @return string frame The packed binary frame
function M.pack_ping_frame(ts)
	return frame.pack(M.type.ping, encode.u64(ts))
end

--- Pack a pong frame with timestamp
--- @param ts integer Timestamp in milliseconds
--- @return string frame The packed binary frame
function M.pack_pong_frame(ts)
	return frame.pack(M.type.pong, encode.u64(ts))
end

--- Pack a task request frame
--- @param id integer Task ID (0 for new requests, leader assigns real ID)
--- @param type_id integer Task type identifier
--- @param data string Encoded task payload data
--- @return string frame The packed binary frame
function M.pack_task_request_frame(id, type_id, data)
	return frame.pack(M.type.task_request, encode.u32(id) .. encode.u8(type_id) .. encode.pack_str_u16(data))
end

--- Pack a task dispatch frame (leader -> followers)
--- @param id integer Task ID assigned by leader
--- @param type_id integer Task type identifier
--- @param data string Encoded task payload data
--- @return string frame The packed binary frame
function M.pack_task_dispatch_frame(id, type_id, data)
	return frame.pack(M.type.task_dispatch, encode.u32(id) .. encode.u8(type_id) .. encode.pack_str_u16(data))
end

--- Pack a task capable frame (follower -> leader)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_capable_frame(id)
	return frame.pack(M.type.task_capable, encode.u32(id))
end

--- Pack a task granted frame (leader -> follower)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_granted_frame(id)
	return frame.pack(M.type.task_granted, encode.u32(id))
end

--- Pack a task denied frame (leader -> follower)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_denied_frame(id)
	return frame.pack(M.type.task_denied, encode.u32(id))
end

--- Pack a task pending frame (leader -> requester)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_pending_frame(id)
	return frame.pack(M.type.task_pending, encode.u32(id))
end

--- Pack a task completed frame (leader -> requester)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_completed_frame(id)
	return frame.pack(M.type.task_completed, encode.u32(id))
end

--- Pack a task failed frame (leader -> requester)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_failed_frame(id)
	return frame.pack(M.type.task_failed, encode.u32(id))
end

--- Pack a task not capable frame (follower -> leader)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_not_capable_frame(id)
	return frame.pack(M.type.task_not_capable, encode.u32(id))
end

--- Pack a task exec done frame (follower -> leader)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_exec_done_frame(id)
	return frame.pack(M.type.task_exec_done, encode.u32(id))
end

--- Pack a task exec failed frame (follower -> leader)
--- @param id integer Task ID
--- @return string frame The packed binary frame
function M.pack_task_exec_failed_frame(id)
	return frame.pack(M.type.task_exec_failed, encode.u32(id))
end

--- Ping/Pong payload structure
--- @class PingPongPayload
--- @field ts integer Timestamp in milliseconds

--- Task request/dispatch payload structure
--- @class TaskRequestPayload
--- @field id integer Task ID
--- @field type_id integer Task type identifier
--- @field data string Encoded task payload

--- Task ID-only payload structure (for capable/granted/denied)
--- @class TaskIdPayload
--- @field id integer Task ID

--- Unpack a message frame and decode its payload
--- @param buf string The binary buffer to unpack
--- @return integer? msg_type The message type, or nil on error
--- @return PingPongPayload|TaskRequestPayload|TaskIdPayload|nil payload The decoded payload, or nil on error
--- @return string? err Error message if unpacking failed
function M.unpack_frame(buf)
	local msg_type, payload, err = frame.unpack(buf)
	if err or not payload then
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
	elseif
		msg_type == M.type.task_capable
		or msg_type == M.type.task_granted
		or msg_type == M.type.task_denied
		or msg_type == M.type.task_pending
		or msg_type == M.type.task_completed
		or msg_type == M.type.task_failed
		or msg_type == M.type.task_not_capable
		or msg_type == M.type.task_exec_done
		or msg_type == M.type.task_exec_failed
	then
		data.id, _, err = encode.unpack_u32(payload, 1)
	else
		return nil, nil, "unknown cmd_id=" .. msg_type
	end
	if err ~= nil then
		return nil, nil, err
	end
	return msg_type, data, nil
end

--- Log a command and its payload for debugging
--- @param cmd_id integer The command/message type ID
--- @param payload table The decoded payload to log
function M.trace_log_cmd(cmd_id, payload)
	if not logger.is_trace() then return end
	logger.trace("cmd = " .. M.get_name(cmd_id))
	logger.trace_dump(payload)
	logger.trace("---")
end

return M
