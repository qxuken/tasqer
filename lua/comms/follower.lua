--- Follower role handlers and helpers.
--- @class CommsFollower

local G = require("lua.G")
local uv = require("lua.uv_wrapper")
local logger = require("lua.logger")
local message = require("lua.message.mod")
local tasks = require("lua.tasks.mod")
local constants = require("lua.comms.constants")

local M = {}

--- Create a new follower role state
--- @param socket uv_udp_t The bound UDP socket
--- @param timer uv_timer_t The heartbeat timer
--- @return FollowerRole role The new follower role state
local function new_follower_role(socket, timer)
	return {
		id = constants.role.follower,
		role = constants.role.follower,
		socket = socket,
		heartbeat_timer = timer,
		last_pong_time = nil,
		tasks = {},
	}
end

--- Send a frame to the leader
--- @param frame string The binary frame to send
local function send_to_leader(frame)
	G.role.socket:send(frame, G.HOST, G.PORT, function(send_err)
		if send_err ~= nil then
			logger.debug("send_to_leader error: " .. send_err)
		end
	end)
end

--- Follower: Handle task_dispatch message from leader
--- @param data TaskRequestPayload The decoded task dispatch payload
local function follower_on_task_dispatch(data)
	local task_id = data.id
	local type_id = data.type_id
	local raw_data = data.data
	G.last_command_id = math.max(G.last_command_id, task_id)

	local payload, err = tasks.decode_task(type_id, raw_data)
	if err or not payload then
		logger.error("Failed to decode task: " .. (err or "Unknown error"))
		return
	end

	local task_module = tasks.get(type_id)
	if not task_module then
		logger.error("Unknown task type: " .. type_id)
		return
	end

	logger.debug("Task[" .. task_id .. "] dispatch received, type=" .. type_id)

	G.role.tasks[task_id] = {
		type_id = type_id,
		payload = payload,
		state = constants.task_state.pending,
	}
	-- Check if we can execute this task
	task_module.can_execute(payload, function(capable)
		if capable then
			-- Store task locally in case we get granted
			logger.debug("Task[" .. task_id .. "] sending capable response")
			send_to_leader(message.pack_task_capable_frame(task_id))
		else
			logger.debug("Task[" .. task_id .. "] not capable, sending response")
			send_to_leader(message.pack_task_not_capable_frame(task_id))
			G.role.tasks[task_id] = nil
		end
	end)
end

--- Follower: Handle task_granted message from leader
--- @param data TaskIdPayload The decoded task granted payload
local function follower_on_task_granted(data)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		logger.warn("Task[" .. task_id .. "] granted but not found locally")
		return
	end

	if task.state ~= constants.task_state.pending then
		logger.warn("Task[" .. task_id .. "] granted but state is not pending: " .. task.state)
		return
	end

	local task_module = tasks.get(task.type_id)
	if not task_module then
		logger.error("Unknown task type: " .. task.type_id)
		return
	end

	logger.info("Task[" .. task_id .. "] granted, executing")
	task.state = constants.task_state.granted
	task_module.execute(task.payload)
	task.state = constants.task_state.completed
	G.role.tasks[task_id] = nil
end

--- Follower: Handle task_denied message from leader
--- @param data TaskIdPayload The decoded task denied payload
local function follower_on_task_denied(data)
	local task_id = data.id
	logger.debug("Task[" .. task_id .. "] denied")
	G.role.tasks[task_id] = nil
end

--- Follower: Handle pong message from leader (heartbeat response)
--- @param data PingPongPayload The decoded pong payload
local function follower_on_pong(data)
	local prev_ts = G.role.last_pong_time
	G.role.last_pong_time = uv.now()
	local diff = 0
	if prev_ts ~= nil then
		diff = G.role.last_pong_time - prev_ts
	end
	logger.debug("Pong received, time_from_last=" .. diff .. "ms, leader_ts=" .. data.ts)
end

--- Route incoming commands to appropriate follower handlers
--- @param cmd_id integer The message type ID
--- @param payload table The decoded message payload
local function on_command(cmd_id, payload)
	if cmd_id == message.type.pong then
		follower_on_pong(payload)
	elseif cmd_id == message.type.task_dispatch then
		follower_on_task_dispatch(payload)
	elseif cmd_id == message.type.task_granted then
		follower_on_task_granted(payload)
	elseif cmd_id == message.type.task_denied then
		follower_on_task_denied(payload)
	end
end

--- Attempt to initialize as follower by connecting to the leader
--- @param on_err function function that triggers restart
--- @return string? err Error message if initialization failed
--- @return integer? code Error code if initialization failed
function M.try_init(on_err)
	logger.debug("try_init_follower")
	local socket, err, code = uv.bind_as_client(uv.recv_buf(function(buf, port)
		local cmd_id, payload, err = message.unpack_frame(buf)
		if err ~= nil or port ~= G.PORT or cmd_id == nil or payload == nil then
			logger.debug("recv_msg -> [err] " .. err)
			return
		end
		message.debug_log_cmd(cmd_id, payload)
		on_command(cmd_id, payload)
	end, function(err)
		if err ~= nil then
			on_err()
		end
	end))
	if err ~= nil or socket == nil then
		return err, code
	end
	local interval_ms = constants.HEARTBEAT_INTERVAL
		+ math.random(constants.HEARTBEAT_RANGE_FROM, constants.HEARTBEAT_RANGE_TO)
	local timer = uv.set_interval(interval_ms, function()
		local now = uv.now()
		if G.role.last_pong_time ~= nil and (now - G.role.last_pong_time) > constants.HEARTBEAT_TIMEOUT then
			logger.debug("Leader timeout: " .. (now - G.role.last_pong_time))
			on_err()
		else
			G.role.socket:send(message.pack_ping_frame(now), nil, nil, function(send_err)
				if send_err ~= nil then
					logger.debug(send_err)
				end
			end)
		end
	end)
	logger.debug("sendings pings per " .. interval_ms .. "ms")
	G.role = new_follower_role(socket, timer)
	return nil, nil
end

--- Cleanup given role
--- @param role FollowerRole
function M.cleanup_role(role)
	uv.clear_timer(role.heartbeat_timer)
end

return M
