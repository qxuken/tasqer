--- Follower role handlers and helpers.
--- @class CommsFollower

local G = require("tasqer.G")
local uv = require("tasqer.uv_wrapper")
local logger = require("tasqer.logger")
local message = require("tasqer.message.mod")
local tasks = require("tasqer.tasks.mod")
local constants = require("tasqer.comms.constants")

local M = {}

--- Stop and clear a task's timeout timer
--- @param task FollowerTaskEntry? The task to stop timer for
local function stop_task_timer(task)
	if task and task.timeout_timer then
		pcall(uv.clear_timer, task.timeout_timer)
		task.timeout_timer = nil
	end
end

--- Create a new follower role state
--- @param socket uv_udp_t The bound UDP socket
--- @param timer uv_timer_t The heartbeat timer
--- @return FollowerRole role The new follower role state
local function new_role(socket, timer)
	return {
		id = constants.role.follower,
		socket = socket,
		heartbeat_timer = timer,
		last_pong_time = nil,
		tasks = {},
	}
end

--- Send a frame to the leader
--- @param frame string The binary frame to send
local function send_to_leader(frame)
	if not G.role or not G.role.socket then
		return
	end
	G.role.socket:send(frame, nil, nil, function(err)
		if err ~= nil then
			if logger.is_debug() then
				logger.debug("send_to_leader error: " .. err)
			end
		end
	end)
end

--- Follower: Handle task_dispatch message from leader
--- @param data TaskRequestPayload The decoded task dispatch payload
local function on_task_dispatch(data)
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

	if logger.is_debug() then
		logger.debug("Task[" .. task_id .. "] dispatch received, type=" .. type_id)
	end

	-- Store task with pending timeout in case leader fails to respond
	local task = {
		type_id = type_id,
		payload = payload,
		state = constants.task_state.pending,
		timeout_timer = nil,
	}
	G.role.tasks[task_id] = task

	-- Set pending timeout - remove task if leader doesn't respond in time
	task.timeout_timer = uv.set_timeout(constants.TASK_EXECUTION_TIMEOUT, function()
		local t = G.role.tasks[task_id]
		if t and t.state == constants.task_state.pending then
			if logger.is_debug() then
				logger.debug("Task[" .. task_id .. "] pending timeout, removing")
			end
			G.role.tasks[task_id] = nil
		end
	end)

	-- Check if we can execute this task
	task_module.can_execute(payload, function(capable)
		local t = G.role.tasks[task_id]
		if not t then
			return -- Task was already removed by timeout
		end
		if capable then
			if logger.is_debug() then
				logger.debug("Task[" .. task_id .. "] sending capable response")
			end
			send_to_leader(message.pack_task_capable_frame(task_id))
		else
			if logger.is_debug() then
				logger.debug("Task[" .. task_id .. "] not capable, sending response")
			end
			send_to_leader(message.pack_task_not_capable_frame(task_id))
			stop_task_timer(t)
			G.role.tasks[task_id] = nil
		end
	end)
end

--- Follower: Handle task_granted message from leader
--- @param data TaskIdPayload The decoded task granted payload
local function on_task_granted(data)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		logger.warn("Task[" .. task_id .. "] granted but not found locally")
		send_to_leader(message.pack_task_exec_failed_frame(task_id))
		return
	end

	if task.state ~= constants.task_state.pending then
		logger.warn("Task[" .. task_id .. "] granted but state is not pending: " .. task.state)
		return
	end

	---@diagnostic disable-next-line: param-type-mismatch
	stop_task_timer(task)

	local task_module = tasks.get(task.type_id)
	if not task_module then
		logger.error("Unknown task type: " .. task.type_id)
		return
	end

	logger.info("Task[" .. task_id .. "] granted, executing")
	task.state = constants.task_state.in_progress
	task_module.execute(task.payload, function(result)
		task.state = constants.task_state.completed
		G.role.tasks[task_id] = nil
		if result then
			send_to_leader(message.pack_task_exec_done_frame(task_id))
		else
			send_to_leader(message.pack_task_exec_failed_frame(task_id))
		end
	end)
end

--- Follower: Handle task_denied message from leader
--- @param data TaskIdPayload The decoded task denied payload
local function on_task_denied(data)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] denied but not found locally")
		end
		return
	end

	if logger.is_debug() then
		logger.debug("Task[" .. task_id .. "] denied, scheduling cleanup")
	end

	---@diagnostic disable-next-line: param-type-mismatch
	stop_task_timer(task)

	-- Set state to denied and schedule delayed cleanup
	task.state = constants.task_state.denied
	task.timeout_timer = uv.set_timeout(constants.TASK_DENIED_CLEANUP_TIMEOUT, function()
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] denied cleanup complete")
		end
		G.role.tasks[task_id] = nil
	end)
end

--- Follower: Handle pong message from leader (heartbeat response)
--- @param data PingPongPayload The decoded pong payload
local function on_pong(data)
	local prev_ts = G.role.last_pong_time
	G.role.last_pong_time = uv.now()
	local diff = 0
	if prev_ts ~= nil then
		diff = G.role.last_pong_time - prev_ts
	end
	if logger.is_debug() then
		logger.debug("Pong received, time_from_last=" .. diff .. "ms, leader_ts=" .. data.ts)
	end
end

--- Route incoming commands to appropriate follower handlers
--- @param cmd_id integer The message type ID
--- @param payload table The decoded message payload
local function on_command(cmd_id, payload)
	if cmd_id == message.type.pong then
		on_pong(payload)
	elseif cmd_id == message.type.task_dispatch then
		on_task_dispatch(payload)
	elseif cmd_id == message.type.task_granted then
		on_task_granted(payload)
	elseif cmd_id == message.type.task_denied then
		on_task_denied(payload)
	end
end

--- Attempt to initialize as follower by connecting to the leader
--- @param on_err function function that triggers restart
--- @return string? err Error message if initialization failed
function M.try_init(on_err)
	logger.debug("try_init_follower")
	local socket, err = uv.bind_as_client(uv.recv_buf(function(buf, port)
		local cmd_id, payload, err = message.unpack_frame(buf)
		if err ~= nil or port ~= G.PORT or cmd_id == nil or payload == nil then
			if logger.is_debug() then
				logger.debug("recv_msg -> [err] " .. (err or "unknown"))
			end
			return
		end
		message.trace_log_cmd(cmd_id, payload)
		on_command(cmd_id, payload)
	end, function(err)
		if err ~= nil then
			on_err()
		end
	end))
	if err ~= nil or socket == nil then
		return err
	end
	local interval_ms = constants.HEARTBEAT_INTERVAL
		+ math.random(constants.HEARTBEAT_RANGE_FROM, constants.HEARTBEAT_RANGE_TO)
	local timer = uv.set_interval(interval_ms, function()
		local now = uv.now()
		if not G.role.last_pong_time then
			G.role.last_pong_time = now
		elseif (now - G.role.last_pong_time) > constants.HEARTBEAT_TIMEOUT then
			if logger.is_debug() then
				logger.debug("Leader timeout: " .. (now - G.role.last_pong_time))
			end
			on_err()
		end
		send_to_leader(message.pack_ping_frame(now))
	end)
	if logger.is_debug() then
		logger.debug("sending pings every " .. interval_ms .. "ms")
	end
	G.role = new_role(socket, timer)
	return nil
end

--- Cleanup given role
--- @param role FollowerRole
function M.cleanup_role(role)
	pcall(uv.clear_timer, role.heartbeat_timer)
	for _, task in pairs(role.tasks) do
		stop_task_timer(task)
	end
end

return M
