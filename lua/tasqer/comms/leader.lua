--- Leader role handlers and helpers.
--- @class CommsLeader

local G = require("tasqer.G")
local uv = require("tasqer.uv_wrapper")
local logger = require("tasqer.logger")
local message = require("tasqer.message.mod")
local tasks = require("tasqer.tasks.mod")
local c = require("tasqer.comms.constants")

local M = {}

--- Create a new leader role state
--- @param socket uv_udp_t The bound UDP socket
--- @return LeaderRole role The new leader role state
local function new_role(socket)
	return {
		id = c.role.leader,
		socket = socket,
		peers = {},
		tasks = {},
	}
end

--- Clean up a task entry and its associated timers
--- @param task FollowerTaskEntry|LeaderTaskEntry The task ID to clean up
local function stop_task(task)
	if not task then
		return
	end
	local timer = task.timeout_timer
	task.timeout_timer = nil
	pcall(uv.clear_timer, timer)
end

--- Ensure a peer's timer is stopped and removed
--- @param port integer The peer's port number
local function ensure_peer_closed(port)
	local peer = G.role.peers[port]
	if not peer then
		return
	end
	G.role.peers[port] = nil
	pcall(uv.clear_timer, peer)
end

--- Reset the timeout timer for a peer (called on each ping received)
--- @param port integer The peer's port number
local function reset_peer_timer(port)
	ensure_peer_closed(port)
	G.role.peers[port] = uv.set_timeout(c.HEARTBEAT_TIMEOUT, function()
		G.role.peers[port] = nil
	end)
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

--- Clean up a task entry and its associated timers
--- Also sends denial to all capable peers except the one that completed the task
--- @param task_id integer The task ID to clean up
local function cleanup_task(task_id)
	local task = G.role.tasks[task_id]
	if not task then
		return
	end
	G.role.tasks[task_id] = nil
	stop_task(task)

	-- Deny all capable peers except the one that completed the task
	for _, port in ipairs(task.capable_peers or {}) do
		if port ~= task.granted_peer then
			send_frame_to_peer(port, message.pack_task_denied_frame(task_id))
		end
	end
end

--- Attempt to grant task to next capable peer, or fail if none left
--- @param task_id integer The task ID
local function try_grant_next_peer(task_id)
	local task = G.role.tasks[task_id]
	if not task then
		return
	end

	-- Stop current timeout timer
	stop_task(task)

	-- Remove current granted peer from capable list
	if task.granted_peer then
		for i, port in ipairs(task.capable_peers) do
			if port == task.granted_peer then
				table.remove(task.capable_peers, i)
				break
			end
		end
		task.granted_peer = nil
	end

	-- Check if any capable peers remain
	if #task.capable_peers == 0 then
		logger.warn("Task[" .. task_id .. "] no more capable peers, failing")
		send_frame_to_peer(task.requester_port, message.pack_task_failed_frame(task.requester_task_id))
		cleanup_task(task_id)
		return
	end

	-- Grant to next capable peer
	local next_port = task.capable_peers[1]
	logger.info("Task[" .. task_id .. "] granting to port " .. next_port)
	task.granted_peer = next_port
	task.state = c.task_state.granted

	-- Start execution timeout timer
	task.timeout_timer = uv.set_timeout(c.TASK_EXECUTION_TIMEOUT, function()
		local t = G.role.tasks[task_id]
		if not t or t.state ~= c.task_state.granted then
			return
		end
		t.timeout_timer = nil
		logger.warn("Task[" .. task_id .. "] execution timeout from port " .. t.granted_peer)
		try_grant_next_peer(task_id)
	end)

	send_frame_to_peer(next_port, message.pack_task_granted_frame(task_id))
end

--- Generate the next unique task ID
--- @return integer id The new task ID
local function next_task_id()
	G.last_command_id = G.last_command_id + 1
	--- Check u32 overflow
	if G.last_command_id > 0xFFFFFFFF then
		G.last_command_id = 1
	end
	return G.last_command_id
end

--- Broadcast a frame to all connected peers
--- @param frame string The binary frame to broadcast
--- @param requester_port integer The original requester's port (may not be a peer)
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

--- Dispatch task to followers
--- @param task_id number
local function dispatch_task_to_followers(task_id)
	local task = G.role.tasks[task_id]
	if not task then
		return
	end
	if logger.is_debug() then
		logger.debug("Task[" .. task_id .. "] dispatching to followers")
	end
	task.state = c.task_state.dispatched

	-- Set up dispatch timeout timer
	task.timeout_timer = uv.set_timeout(c.TASK_DISPATCH_TIMEOUT, function()
		local t = G.role.tasks[task_id]
		if not t or t.state ~= c.task_state.dispatched then
			return
		end
		--- The timer is closed by this time
		t.timeout_timer = nil
		cleanup_task(task_id)
		logger.warn("Task[" .. task_id .. "] dispatch timeout, no capable followers")
		send_frame_to_peer(t.requester_port, message.pack_task_failed_frame(t.requester_task_id))
	end)

	task.dispatched_count =
		broadcast_to_peers(message.pack_task_dispatch_frame(task_id, task.type_id, task.raw_data), task.requester_port)
	if task.dispatched_count == 0 then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] no peers available to dispatch")
		end
		cleanup_task(task_id)
		send_frame_to_peer(task.requester_port, message.pack_task_failed_frame(task.requester_task_id))
		return
	end
end

--- Leader: Handle incoming task_request message
--- @param data TaskRequestPayload The decoded task request payload
--- @param requester_port integer The port of the requester
local function on_task_request(data, requester_port)
	assert(type(requester_port) == "number", "requester port should be a number")
	local requester_task_id = data.id
	local task_id = next_task_id()
	local type_id = data.type_id
	local raw_data = data.data

	-- Send pending acknowledgment to requester immediately
	send_frame_to_peer(requester_port, message.pack_task_pending_frame(requester_task_id))

	local payload, err = tasks.decode_task(type_id, raw_data)
	if err or not payload then
		logger.error("Failed to decode task: " .. (err or "Unknown error"))
		send_frame_to_peer(requester_port, message.pack_task_failed_frame(requester_task_id))
		return
	end

	local task_module = tasks.get(type_id)
	if not task_module then
		logger.error("Unknown task type: " .. type_id)
		send_frame_to_peer(requester_port, message.pack_task_failed_frame(requester_task_id))
		return
	end

	if logger.is_debug() then
		logger.debug(
			"Task[" .. task_id .. "] request received from port " .. tostring(requester_port) .. ", type=" .. type_id
		)
	end

	G.role.tasks[task_id] = {
		requester_task_id = requester_task_id,
		requester_port = requester_port,
		type_id = type_id,
		payload = payload,
		raw_data = raw_data,
		state = c.task_state.pending,
		capable_peers = {},
		granted_peer = nil,
		dispatched_count = 0,
		not_capable_count = 0,
		timeout_timer = nil,
	}

	task_module.can_execute(payload, function(capable)
		local task = G.role.tasks[task_id]
		if not task then
			return
		end

		if capable then
			logger.info("Task[" .. task_id .. "] executing locally (leader capable)")
			task_module.execute(payload, function(result)
				local t = G.role.tasks[task_id]
				if not t or t.state == c.task_state.completed then
					return
				end
				if result then
					t.state = c.task_state.completed
					cleanup_task(task_id)
					send_frame_to_peer(t.requester_port, message.pack_task_completed_frame(t.requester_task_id))
				else
					logger.warn("Execution failed")
					dispatch_task_to_followers(task_id)
				end
			end)
		else
			dispatch_task_to_followers(task_id)
		end
	end)
end

--- Leader: Handle task_capable response from a follower
--- @param data TaskIdPayload The decoded task capable payload
--- @param port integer The responding follower's port
local function on_task_capable(data, port)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] capable from port " .. port .. " - task not found")
		end
		send_frame_to_peer(port, message.pack_task_denied_frame(task_id))
		return
	end

	-- Add to capable peers list (will be denied on task cleanup if not granted)
	table.insert(task.capable_peers, port)

	if task.state ~= c.task_state.dispatched then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] capable from port " .. port)
		end
		return
	end
	task.state = c.task_state.granted

	try_grant_next_peer(task_id)
end

--- Leader: Handle task_not_capable response from a follower
--- @param data TaskIdPayload The decoded task not capable payload
--- @param port integer The responding follower's port
local function on_task_not_capable(data, port)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] not_capable from port " .. port .. " - task not found")
		end
		return
	end

	task.not_capable_count = task.not_capable_count + 1
	if task.state ~= c.task_state.dispatched then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] not_capable from port " .. port .. " - wrong state: " .. task.state)
		end
		return
	end

	if logger.is_debug() then
		logger.debug(
			"Task["
				.. task_id
				.. "] not_capable from port "
				.. port
				.. " ("
				.. task.not_capable_count
				.. "/"
				.. task.dispatched_count
				.. ")"
		)
	end

	if task.not_capable_count >= task.dispatched_count then
		logger.warn("Task[" .. task_id .. "] all " .. task.dispatched_count .. " followers not capable")
		send_frame_to_peer(task.requester_port, message.pack_task_failed_frame(task.requester_task_id))
		cleanup_task(task_id)
	end
end

--- Leader: Handle task_exec_done response from a follower
--- @param data TaskIdPayload The decoded payload
--- @param port integer The responding follower's port
local function on_task_exec_done(data, port)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] exec_done from port " .. port .. " - task not found")
		end
		return
	end

	if task.state ~= c.task_state.granted or task.granted_peer ~= port then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] exec_done from port " .. port .. " - wrong state or peer")
		end
		return
	end

	logger.info("Task[" .. task_id .. "] completed by port " .. port)
	send_frame_to_peer(task.requester_port, message.pack_task_completed_frame(task.requester_task_id))
	cleanup_task(task_id)
end

--- Leader: Handle task_exec_failed response from a follower
--- @param data TaskIdPayload The decoded payload
--- @param port integer The responding follower's port
local function on_task_exec_failed(data, port)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] exec_failed from port " .. port .. " - task not found")
		end
		return
	end

	if task.state ~= c.task_state.granted or task.granted_peer ~= port then
		if logger.is_debug() then
			logger.debug("Task[" .. task_id .. "] exec_failed from port " .. port .. " - wrong state or peer")
		end
		return
	end

	logger.warn("Task[" .. task_id .. "] execution failed by port " .. port .. ", trying next peer")
	try_grant_next_peer(task_id)
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
local function on_command(cmd_id, payload, port)
	if cmd_id == message.type.ping then
		on_ping(port)
	elseif cmd_id == message.type.task_request then
		on_task_request(payload, port)
	elseif cmd_id == message.type.task_capable then
		on_task_capable(payload, port)
	elseif cmd_id == message.type.task_not_capable then
		on_task_not_capable(payload, port)
	elseif cmd_id == message.type.task_exec_done then
		on_task_exec_done(payload, port)
	elseif cmd_id == message.type.task_exec_failed then
		on_task_exec_failed(payload, port)
	end
end

--- Attempt to initialize as leader by binding to the main port
--- @param on_err function function that triggers restart
--- @return string? err Error message if initialization failed
function M.try_init(on_err)
	logger.debug("try_init_leader")
	local socket, err = uv.bind_as_server(uv.recv_buf(function(buf, port)
		assert(buf ~= nil, "recv_msg callback with empty data")
		local cmd_id, payload, err = message.unpack_frame(buf)
		if err ~= nil or cmd_id == nil or payload == nil then
			logger.warn("recv_msg -> [err] " .. err)
			return
		end
		message.trace_log_cmd(cmd_id, payload)
		on_command(cmd_id, payload, port)
	end, function(err)
		if err ~= nil then
			on_err()
		end
	end))
	if err ~= nil or socket == nil then
		return err
	end
	G.role = new_role(socket)
	return nil
end

--- Cleanup given role
--- @param role LeaderRole
function M.cleanup_role(role)
	for _, task in pairs(role.tasks) do
		stop_task(task)
	end
end

return M
