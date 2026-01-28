--- Leader role handlers and helpers.
--- @class CommsLeader

local G = require("lua.G")
local uv = require("lua.uv_wrapper")
local logger = require("lua.logger")
local message = require("lua.message.mod")
local tasks = require("lua.tasks.mod")
local constants = require("lua.comms.constants")

local M = {}

--- Create a new leader role state
--- @param socket uv_udp_t The bound UDP socket
--- @return LeaderRole role The new leader role state
local function new_leader_role(socket)
	return {
		id = constants.role.leader,
		role = constants.role.leader,
		socket = socket,
		peers = {},
		tasks = {},
	}
end

--- Clean up a task entry and it's associated timers
--- @param task FollowerTaskEntry|LeaderTaskEntry The task ID to clean up
local function stop_task(task)
	if not task then
		return
	end
	uv.clear_timer(task.dispatch_timer)
end

--- Clean up a task entry and it's associated timers
--- @param task_id integer The task ID to clean up
local function cleanup_task(task_id)
	local task = G.role.tasks[task_id]
	if not task then
		return
	end
	G.role.tasks[task_id] = nil
	stop_task(task)
end

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

--- Reset the timeout timer for a peer (called on each ping received)
--- @param port integer The peer's port number
local function reset_peer_timer(port)
	ensure_peer_closed(port)
	G.role.peers[port] = uv.set_timeout(constants.HEARTBEAT_TIMEOUT, function()
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

--- Generate the next unique task ID
--- @return integer id The new task ID
local function next_task_id()
	G.last_command_id = G.last_command_id + 1
	if G.last_command_id > 0xFFFFFFFF then
		G.last_command_id = 1
	end
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
		"Task[" .. task_id .. "] request received from port " .. tostring(requester_port) .. ", type=" .. type_id
	)

	G.role.tasks[task_id] = {
		type_id = type_id,
		payload = payload,
		raw_data = raw_data,
		state = constants.task_state.pending,
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
			logger.info("Task[" .. task_id .. "] executing locally (leader capable)")
			task_module.execute(payload)
			task.state = constants.task_state.completed
			-- Send completed to requester
			if task.requester_port then
				send_frame_to_peer(task.requester_port, message.pack_task_completed_frame(task_id))
			end
			cleanup_task(task_id)
		else
			logger.debug("Task[" .. task_id .. "] dispatching to followers")
			task.state = constants.task_state.dispatched

			-- Set up dispatch timeout timer
			task.dispatch_timer = uv.set_timeout(constants.TASK_DISPATCH_TIMEOUT, function()
				local t = G.role.tasks[task_id]
				if not t or t.state ~= constants.task_state.dispatched then
					return
				end
				logger.warn("Task[" .. task_id .. "] dispatch timeout, no capable followers")
				if t.requester_port then
					send_frame_to_peer(t.requester_port, message.pack_task_failed_frame(task_id))
				end
				t.dispatch_timer = nil
				cleanup_task(task_id)
			end)

			task.dispatched_count =
				broadcast_to_peers(message.pack_task_dispatch_frame(task_id, type_id, raw_data), task.requester_port)
			if task.dispatched_count == 0 then
				logger.debug("Task[" .. task_id .. "] no peers available to dispatch")
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
		logger.debug("Task[" .. task_id .. "] capable from port " .. port .. " - task not found")
		send_frame_to_peer(port, message.pack_task_denied_frame(task_id))
		return
	end

	if task.state ~= constants.task_state.dispatched then
		logger.debug("Task[" .. task_id .. "] capable from port " .. port .. " - wrong state: " .. task.state)
		send_frame_to_peer(port, message.pack_task_denied_frame(task_id))
		return
	end

	-- First capable peer gets the task
	logger.info("Task[" .. task_id .. "] granting to port " .. port)
	task.state = constants.task_state.granted
	task.granted_peer = port
	table.insert(task.capable_peers, port)

	-- Stop dispatch timer since we found a capable peer
	if task.dispatch_timer then
		uv.clear_timer(task.dispatch_timer)
		task.dispatch_timer = nil
	end

	send_frame_to_peer(port, message.pack_task_granted_frame(task_id))

	-- Send completed to requester (assumes execution succeeds once granted)
	if task.requester_port then
		send_frame_to_peer(task.requester_port, message.pack_task_completed_frame(task_id))
	end

	cleanup_task(task_id)
end

--- Leader: Handle task_not_capable response from a follower
--- @param data TaskIdPayload The decoded task not capable payload
--- @param port integer The responding follower's port
local function leader_on_task_not_capable(data, port)
	local task_id = data.id
	local task = G.role.tasks[task_id]

	if not task then
		logger.debug("Task[" .. task_id .. "] not_capable from port " .. port .. " - task not found")
		return
	end

	if task.state ~= constants.task_state.dispatched then
		logger.debug("Task[" .. task_id .. "] not_capable from port " .. port .. " - wrong state: " .. task.state)
		return
	end

	-- Increment not_capable count
	task.not_capable_count = task.not_capable_count + 1
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

	-- If all dispatched peers responded not_capable, fail the task
	if task.not_capable_count >= task.dispatched_count then
		logger.warn("Task[" .. task_id .. "] all " .. task.dispatched_count .. " followers not capable")
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
local function on_command(cmd_id, payload, port)
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

--- Attempt to initialize as leader by binding to the main port
--- @param on_err function function that triggers restart
--- @return string? err Error message if initialization failed
--- @return integer? code Error code if initialization failed
function M.try_init(on_err)
	logger.debug("try_init_leader")
	local socket, err, code = uv.bind_as_server(uv.recv_buf(function(buf, port)
		assert(buf ~= nil, "recv_msg callback with empty data")
		local cmd_id, payload, err = message.unpack_frame(buf)
		if err ~= nil or cmd_id == nil or payload == nil then
			logger.warn("recv_msg -> [err] " .. err)
			return
		end
		message.debug_log_cmd(cmd_id, payload)
		on_command(cmd_id, payload, port)
	end, function(err)
		if err ~= nil then
			on_err()
		end
	end))
	if err ~= nil or socket == nil then
		return err, code
	end
	G.role = new_leader_role(socket)
	return nil, nil
end

--- Cleanup given role
--- @param role LeaderRole
function M.cleanup_role(role)
	for _, task in ipairs(role.tasks) do
		stop_task(task)
	end
	for port in pairs(role.peers) do
		ensure_peer_closed(port)
	end
end

return M
