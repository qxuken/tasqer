--- Issuer role handlers and helpers.
--- @class CommsIssuer

local G = require("tasqer.G")
local uv = require("tasqer.uv_wrapper")
local logger = require("tasqer.logger")
local message = require("tasqer.message.mod")
local tasks = require("tasqer.tasks.mod")
local c = require("tasqer.comms.constants")

local M = {}

--- Create a new follower role state
--- @param task IssuerTaskEntry The task
--- @param shutdown fun() Comms shutdown procedure
--- @param socket uv_udp_t The bound UDP socket
--- @param heartbeat_timer uv_timer_t The heartbeat timer
--- @param dispatch_timer uv_timer_t Deadline for a cluster to complete a task
--- @return IssuerRole role The new follower role state
local function new_role(task, shutdown, socket, heartbeat_timer, dispatch_timer)
	return {
		id = c.role.issuer,
		task = task,
		socket = socket,
		shutdown = shutdown,
		heartbeat_timer = heartbeat_timer,
		dispatch_timer = dispatch_timer,
		last_pong_time = nil,
	}
end

--- Shutdown comms
local function shutdown_comms()
	if G.role.shutdown then
		G.role.shutdown()
	end
end

--- Shutdown comms and try execute task
local function shutdown_and_try_execute_task()
	local task = G.role.task
	shutdown_comms()
	M.try_execute_task(task)
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
			shutdown_and_try_execute_task()
		end
	end)
end

--- Try execute task and stops uv after any type of result
function M.try_execute_task(task)
	if task.state == c.task_state.in_progress or task.state == c.task_state.completed then
		return
	end
	task.state = c.task_state.in_progress
	return tasks.try_execute(task.type_id, task.payload, function(done)
		if not done then
			logger.error("Cannot complete task")
		end
		uv.stop()
	end)
end

local function on_task_pending(payload)
	pcall(uv.clear_timer, G.role.dispatch_timer)
	G.role.dispatch_timer = uv.set_timeout(c.ISSUER_COMPLETION_TIMEOUT, shutdown_and_try_execute_task)
	if logger.is_debug() then
		logger.debug_dump(payload)
	end
end

local function on_task_complete()
	uv.stop()
	logger.info("Task complete")
end

local function on_task_failed()
	shutdown_and_try_execute_task()
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
	elseif cmd_id == message.type.task_pending then
		on_task_pending(payload)
	elseif cmd_id == message.type.task_completed then
		on_task_complete(payload)
	elseif cmd_id == message.type.task_failed then
		on_task_failed(payload)
	end
end

--- Dispatch the task to the leader
local function dispatch_task_to_leader()
	local task = G.role.task
	local task_payload, err = tasks.encode_task(task.type_id, task.payload)
	if err ~= nil or task_payload == nil then
		uv.stop()
		logger.warn(err or "Task encoding error")
		return err
	end
	send_to_leader(message.pack_task_request_frame(0, task.type_id, task_payload))
	task.state = c.task_state.dispatched
end

--- Attempt to initialize as issuer by connecting to the leader
--- @param task IssuerTaskEntry The task
--- @param shutdown fun() Comms shutdown procedure
--- @param on_err function function that triggers restart
--- @return string? err Error message if initialization failed
function M.try_init(task, shutdown, on_err)
	logger.debug("try_init_issuer")
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
	local heartbeat_timer = uv.set_interval(c.ISSUER_PING_INTERVAL, function()
		local now = uv.now()
		if not G.role.last_pong_time then
			G.role.last_pong_time = now
		elseif (now - G.role.last_pong_time) > c.ISSUER_PING_TIMEOUT then
			if logger.is_debug() then
				logger.debug("Leader timeout: " .. (now - G.role.last_pong_time))
			end
			on_err()
		end
		send_to_leader(message.pack_ping_frame(now))
	end)
	if logger.is_debug() then
		logger.debug("sending pings every " .. c.ISSUER_PING_INTERVAL .. "ms")
	end
	local dispatch_timer = uv.set_timeout(c.ISSUER_PENDING_TIMEOUT, shutdown_and_try_execute_task)
	G.role = new_role(task, shutdown, socket, heartbeat_timer, dispatch_timer)
	dispatch_task_to_leader()
	return nil
end

--- Cleanup given role
--- @param role IssuerRole
function M.cleanup_role(role)
	pcall(uv.clear_timer, role.dispatch_timer)
	pcall(uv.clear_timer, role.heartbeat_timer)
end

return M
