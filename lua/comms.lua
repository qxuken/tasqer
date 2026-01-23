--- Communication layer for leader-follower coordination.
--- Handles role election, task routing, and peer management.
--- @class CommsModule

local G = require("lua.G")
local logger = require("lua.logger")
local uv = require("lua.uv_wrapper")
local message = require("lua.message.mod")
local tasks = require("lua.tasks.mod")

--- @class CommsModule
local M = {}

--- @type integer Timeout before considering a peer disconnected (ms)
local HEARTBEAT_TIMEOUT = 6000
--- @type integer Base interval between heartbeat pings (ms)
local HEARTBEAT_INTERVAL = 2000
--- @type integer Minimum random jitter added to heartbeat interval (ms)
local HEARTBEAT_RANGE_FROM = 250
--- @type integer Maximum random jitter added to heartbeat interval (ms)
local HEARTBEAT_RANGE_TO = 1750

--- @type integer Timeout waiting for capable responses from followers (ms)
local TASK_DISPATCH_TIMEOUT = 3000

--- Role identifier constants
--- @enum RoleId
M.role = {
	candidate = 0,
	follower = 1,
	leader = 2,
}

--- Task state constants for tracking task lifecycle
--- @enum TaskState
M.task_state = {
	pending = 0, -- Task received, checking local capability
	dispatched = 1, -- Dispatched to followers, waiting for capable responses
	granted = 2, -- Granted to a follower
	completed = 3, -- Task completed
}

--- Default candidate role state
--- @return CandidateRole
local function new_candidate_role()
	return {
		id = M.role.candidate,
	}
end
G.role = new_candidate_role()
-- FIX: select max in followers, so when it becomes leader it will not break sequence
G.last_command_id = 0

--- Ensure a peer's timer is stopped and removed
--- @param port integer The peer's port number
local function ensure_peer_closed(port)
	local peer = G.role.peers[port]
	if not peer then
		return
	end
	G.role.peers[port] = nil
	uv.clear_timer(peer)
end

--- Clean up a task entry and it's associated timers
--- @param task_id integer The task ID to clean up
local function cleanup_task(task_id)
	local task = G.role.tasks[task_id]
	if not task then
		return
	end
	G.role.tasks[task_id] = nil
	uv.clear_timer(task.dispatch_timer)
end

--- Clean up current role state and close socket connections.
--- Resets to candidate role after cleanup.
function M.cleanup_role_and_shutdown_socket()
	if not G.role then
		G.role = new_candidate_role()
		return
	end

	if G.role.id == M.role.candidate then
		return
	end

	G.role.socket:recv_stop()
	if G.role.id == M.role.leader then
		for task_id in pairs(G.role.tasks) do
			cleanup_task(task_id)
		end
		for port in pairs(G.role.peers) do
			ensure_peer_closed(port)
		end
	elseif G.role.id == M.role.follower then
		uv.clear_timer(G.role.heartbeat_timer)
	end
	G.role.socket:close()
	G.role = new_candidate_role()
end

--- Reset the timeout timer for a peer (called on each ping received)
--- @param port integer The peer's port number
local function reset_peer_timer(port)
	ensure_peer_closed(port)
	G.role.peers[port] = uv.set_timeout(HEARTBEAT_TIMEOUT, function()
		G.role.peers[port] = nil
	end)
end

--- Create a new leader role state
--- @param socket uv_udp_t The bound UDP socket
--- @return LeaderRole role The new leader role state
local function new_leader_role(socket)
	return {
		id = M.role.leader,
		role = M.role.leader,
		socket = socket,
		peers = {},
		tasks = {},
	}
end

--- Send a frame to a specific peer
--- @param port integer The target peer's port
--- @param frame string The binary frame to send
local function send_frame_to_peer(port, frame)
	G.role.socket:send(frame, G.HOST, port, function(send_err)
		if send_err ~= nil then
			ensure_peer_closed(port)
			logger.debug(send_err)
		end
	end)
end

--- Generate the next unique task ID
--- @return integer id The new task ID
local function next_task_id()
	-- FIX: it should round about max u32 value
	G.last_command_id = G.last_command_id + 1
	return G.last_command_id
end

--- Broadcast a frame to all connected peers
--- @param frame string The binary frame to broadcast
--- @param requester_port integer? The original requester's port (may not be a peer)
--- @return integer Number of sent frames
local function broadcast_to_peers(frame, requester_port)
	local counter = 0
	for port, _ in pairs(G.role.peers) do
		if port ~= requester_port then
			send_frame_to_peer(port, frame)
			counter = counter + 1
		end
	end
	return counter
end

--- Leader: Handle incoming task_request message
--- @param data TaskRequestPayload The decoded task request payload
--- @param requester_port integer? The port of the requester
local function leader_on_task_request(data, requester_port)
	local task_id = next_task_id()
	local type_id = data.type_id
	local raw_data = data.data

	-- Send pending acknowledgment to requester immediately
	if requester_port then
		send_frame_to_peer(requester_port, message.pack_task_pending_frame(task_id))
	end

	local payload, err = tasks.decode_task(type_id, raw_data)
	if err or not payload then
		logger.error("Failed to decode task: " .. (err or "Unknown error"))
		if requester_port then
			send_frame_to_peer(requester_port, message.pack_task_failed_frame(task_id))
		end
		return
	end

	local task_module = tasks.get(type_id)
	if not task_module then
		logger.error("Unknown task type: " .. type_id)
		if requester_port then
			send_frame_to_peer(requester_port, message.pack_task_failed_frame(task_id))
		end
		return
	end

	logger.debug(
		string.format("Task[%d] request received from port %s, type=%d", task_id, tostring(requester_port), type_id)
	)

	G.role.tasks[task_id] = {
		type_id = type_id,
		payload = payload,
		raw_data = raw_data,
		state = M.task_state.pending,
		capable_peers = {},
		granted_peer = nil,
		requester_port = requester_port,
		dispatched_count = 0,
		not_capable_count = 0,
		dispatch_timer = nil,
	}

	-- Check if leader can execute locally first
	task_module.can_execute(payload, function(capable)
		local task = G.role.tasks[task_id]
		if not task then
			return
		end

		if capable then
			logger.info(string.format("Task[%d] executing locally (leader capable)", task_id))
			task_module.execute(payload)
			task.state = M.task_state.completed
			-- Send completed to requester
			if task.requester_port then
				send_frame_to_peer(task.requester_port, message.pack_task_completed_frame(task_id))
			end
			cleanup_task(task_id)
		else
			logger.debug(string.format("Task[%d] dispatching to followers", task_id))
			task.state = M.task_state.dispatched

			-- Set up dispatch timeout timer
			task.dispatch_timer = uv.set_timeout(TASK_DISPATCH_TIMEOUT, function()
				local t = G.role.tasks[task_id]
				if not t or t.state ~= M.task_state.dispatched then
					return
				end
				logger.warn(string.format("Task[%d] dispatch timeout, no capable followers", task_id))
				if t.requester_port then
					send_frame_to_peer(t.requester_port, message.pack_task_failed_frame(task_id))
				end
				t.dispatch_timer = nil
				cleanup_task(task_id)
			end)

			task.dispatched_count =
				broadcast_to_peers(message.pack_task_dispatch_frame(task_id, type_id, raw_data), task.requester_port)
			if task.dispatched_count == 0 then
				logger.debug(string.format("Task[%d] no peers available to dispatch", task_id))
				cleanup_task(task_id)
				if task.requester_port then
					send_frame_to_peer(task.requester_port, message.pack_task_failed_frame(task_id))
				end
				return
			end
		end
	end)
end

--- Leader: Handle task_capable response from a follower
--- @param data TaskIdPayload The decoded task capable payload
--- @param port integer The responding follower's port
local function leader_on_task_capable(data, port)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		logger.debug(string.format("Task[%d] capable from port %d - task not found", task_id, port))
		send_frame_to_peer(port, message.pack_task_denied_frame(task_id))
		return
	end

	if task.state ~= M.task_state.dispatched then
		logger.debug(string.format("Task[%d] capable from port %d - wrong state: %s", task_id, port, task.state))
		send_frame_to_peer(port, message.pack_task_denied_frame(task_id))
		return
	end

	-- First capable peer gets the task
	logger.info(string.format("Task[%d] granting to port %d", task_id, port))
	task.state = M.task_state.granted
	task.granted_peer = port
	table.insert(task.capable_peers, port)

	-- Stop dispatch timer since we found a capable peer
	if task.dispatch_timer then
		uv.clear_timer(task.dispatch_timer)
		task.dispatch_timer = nil
	end

	-- Grant to the capable follower
	send_frame_to_peer(port, message.pack_task_granted_frame(task_id))

	-- Send completed to requester (assumes execution succeeds once granted)
	if task.requester_port then
		send_frame_to_peer(task.requester_port, message.pack_task_completed_frame(task_id))
	end

	-- Clean up task state
	cleanup_task(task_id)
end

--- Leader: Handle task_not_capable response from a follower
--- @param data TaskIdPayload The decoded task not capable payload
--- @param port integer The responding follower's port
local function leader_on_task_not_capable(data, port)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		logger.debug(string.format("Task[%d] not_capable from port %d - task not found", task_id, port))
		return
	end

	if task.state ~= M.task_state.dispatched then
		logger.debug(string.format("Task[%d] not_capable from port %d - wrong state: %s", task_id, port, task.state))
		return
	end

	-- Increment not_capable count
	task.not_capable_count = task.not_capable_count + 1
	logger.debug(
		string.format(
			"Task[%d] not_capable from port %d (%d/%d)",
			task_id,
			port,
			task.not_capable_count,
			task.dispatched_count
		)
	)

	-- If all dispatched peers responded not_capable, fail the task
	if task.not_capable_count >= task.dispatched_count then
		logger.warn(string.format("Task[%d] all %d followers not capable", task_id, task.dispatched_count))
		if task.requester_port then
			send_frame_to_peer(task.requester_port, message.pack_task_failed_frame(task_id))
		end
		cleanup_task(task_id)
	end
end

--- Handle a ping message from a follower
--- @param port integer The follower's port
local function on_ping(port)
	reset_peer_timer(port)
	send_frame_to_peer(port, message.pack_pong_frame(uv.now()))
end

--- Route incoming commands to appropriate leader handlers
--- @param cmd_id integer The message type ID
--- @param payload table The decoded message payload
--- @param port integer The sender's port
local function on_leader_command(cmd_id, payload, port)
	if cmd_id == message.type.ping then
		on_ping(port)
	elseif cmd_id == message.type.task_request then
		leader_on_task_request(payload, port)
	elseif cmd_id == message.type.task_capable then
		leader_on_task_capable(payload, port)
	elseif cmd_id == message.type.task_not_capable then
		leader_on_task_not_capable(payload, port)
	end
end

--- Create a new follower role state
--- @param socket uv_udp_t The bound UDP socket
--- @param timer uv_timer_t The heartbeat timer
--- @return FollowerRole role The new follower role state
local function new_follower_role(socket, timer)
	return {
		id = M.role.follower,
		role = M.role.follower,
		socket = socket,
		heartbeat_timer = timer,
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

	logger.debug(string.format("Task[%d] dispatch received, type=%d", task_id, type_id))

	G.role.tasks[task_id] = {
		type_id = type_id,
		payload = payload,
		state = M.task_state.pending,
	}
	-- Check if we can execute this task
	task_module.can_execute(payload, function(capable)
		if capable then
			-- Store task locally in case we get granted
			logger.debug(string.format("Task[%d] sending capable response", task_id))
			send_to_leader(message.pack_task_capable_frame(task_id))
		else
			logger.debug(string.format("Task[%d] not capable, sending response", task_id))
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
		logger.warn(string.format("Task[%d] granted but not found locally", task_id))
		return
	end

	if task.state ~= M.task_state.pending then
		logger.warn(string.format("Task[%d] granted but state is not pending: %s", task_id, task.state))
		return
	end

	local task_module = tasks.get(task.type_id)
	if not task_module then
		logger.error("Unknown task type: " .. task.type_id)
		return
	end

	logger.info(string.format("Task[%d] granted, executing", task_id))
	task.state = M.task_state.granted
	task_module.execute(task.payload)
	task.state = M.task_state.completed
	G.role.tasks[task_id] = nil
end

--- Follower: Handle task_denied message from leader
--- @param data TaskIdPayload The decoded task denied payload
local function follower_on_task_denied(data)
	local task_id = data.id
	logger.debug(string.format("Task[%d] denied", task_id))
	G.role.tasks[task_id] = nil
end

--- Follower: Handle pong message from leader (heartbeat response)
--- @param data PingPongPayload The decoded pong payload
local function follower_on_pong(data)
	logger.debug(string.format("Pong received, latency=%dms", math.abs(uv.now() - data.ts)))
end

--- Route incoming commands to appropriate follower handlers
--- @param cmd_id integer The message type ID
--- @param payload table The decoded message payload
local function on_follower_command(cmd_id, payload)
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

--- Attempt to initialize as leader by binding to the main port
--- @return string? err Error message if initialization failed
--- @return integer? code Error code if initialization failed
local function try_init_leader()
	logger.debug("try_init_leader")
	local socket, err, code = uv.bind_as_server(uv.recv_buf(function(buf, port)
		assert(buf ~= nil, "recv_msg callback with empty data")
		local cmd_id, payload, err = message.unpack_frame(buf)
		if err ~= nil or cmd_id == nil or payload == nil then
			logger.warn("recv_msg -> [err] " .. err)
			return
		end
		message.debug_log_cmd(cmd_id, payload)
		on_leader_command(cmd_id, payload, port)
	end, function(err)
		if err ~= nil then
			M.run_comms()
		end
	end))
	if err ~= nil or socket == nil then
		return err, code
	end
	G.role = new_leader_role(socket)
	return nil, nil
end

--- Attempt to initialize as follower by connecting to the leader
--- @return string? err Error message if initialization failed
--- @return integer? code Error code if initialization failed
local function try_init_follower()
	logger.debug("try_init_follower")
	local socket, err, code = uv.bind_as_client(uv.recv_buf(function(buf, port)
		local cmd_id, payload, err = message.unpack_frame(buf)
		if err ~= nil or port ~= G.PORT or cmd_id == nil or payload == nil then
			logger.debug("recv_msg -> [err] " .. err)
			return
		end
		message.debug_log_cmd(cmd_id, payload)
		on_follower_command(cmd_id, payload)
	end, function(err)
		if err ~= nil then
			M.run_comms()
		end
	end))
	if err ~= nil or socket == nil then
		return err, code
	end
	local interval_ms = HEARTBEAT_INTERVAL + math.random(HEARTBEAT_RANGE_FROM, HEARTBEAT_RANGE_TO)
	local timer = uv.set_interval(interval_ms, function()
		G.role.socket:send(message.pack_ping_frame(uv.now()), nil, nil, function(send_err)
			if send_err ~= nil then
				logger.debug(send_err)
			end
		end)
	end)
	logger.debug("sendings pings per " .. interval_ms .. "ms")
	G.role = new_follower_role(socket, timer)
	return nil, nil
end

--- Initialize communication - attempts to become leader, falls back to follower
--- @param retries integer? Number of retry attempts remaining (default: 3)
--- @return boolean success True if successfully initialized
--- @return string? error Error message if all retries exhausted
function M.run_comms(retries)
	local retries_left = retries and retries - 1 or 3
	logger.debug("run_comms: " .. retries_left)
	if retries_left == 0 then
		return false, "No more retries, quiting"
	end
	M.cleanup_role_and_shutdown_socket()
	local err
	err = try_init_leader()
	if err ~= nil then
		logger.trace(err)
		err = try_init_follower()
		if err ~= nil then
			logger.trace(err)
			return M.run_comms(retries_left)
		end
	end
	return true, nil
end

return M
