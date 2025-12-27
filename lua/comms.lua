local G = require("lua.G")
local logger = require("lua.logger")
local uv = require("lua.uv_wrapper")
local message = require("lua.message.mod")

local M = {}

local HEARTBEAT_TIMEOUT = 6000
local HEARTBEAT_INTERVAL = 2000
local HEARTBEAT_RANGE_FROM = 250
local HEARTBEAT_RANGE_TO = 1750

M.role = {
	candidate = 0,
	follower = 1,
	leader = 2,
}

local CANDIDTATE_ROLE = {
	id = M.role.candidate,
}
G.role = CANDIDTATE_ROLE
G.last_command_id = 0

function M.cleanup_role_and_shutdown_socket()
	if not G.role then
		G.role = CANDIDTATE_ROLE
		return
	end
	if G.role.id == M.role.candidate then
		return
	end

	G.role.socket:recv_stop()
	if G.role.id == M.role.leader then
		for port, timer in pairs(G.role.peers) do
			uv.clear_interval(timer)
			G.role.peers[port] = nil
		end
	elseif G.role.id == M.role.follower then
		G.role.heartbeat_timer:stop()
		G.role.heartbeat_timer:close()
	end
	G.role.socket:close()
	G.role = CANDIDTATE_ROLE
end

local function ensure_peer_closed(port)
	if not G.role.peers[port] then
		return
	end
	uv.clear_interval(G.role.peers[port])
	G.role.peers[port] = nil
end

local function reset_peer_timer(port)
	ensure_peer_closed(port)
	G.role.peers[port] = uv.set_timeout(HEARTBEAT_TIMEOUT, function()
		G.role.peers[port] = nil
	end)
end

local function new_leader_role(socket)
	return {
		role = M.role.leader,
		socket = socket,
		peers = {},
		tasks = {},
	}
end

local function send_frame_to_peer(port, frame)
	G.role.socket:send(frame, G.HOST, port, function(send_err)
		if send_err ~= nil then
			ensure_peer_closed(port)
			logger.debug(send_err)
		end
	end)
end

local function on_task_dispatch(payload)
	uv.fstat(payload.path, function(err, stat)
		if not err and stat.type == "file" then
			logger.info("Openning" .. payload.path)
		else
			for port in pairs(G.role.peers) do
			end
		end
	end)
end

local function on_ping(port)
	reset_peer_timer(port)
	send_frame_to_peer(port, message.pack_pong_frame(uv.now()))
end

local function on_leader_command(cmd_id, payload, port)
	if cmd_id == message.type.task_dispatch then
		on_task_dispatch(payload)
	elseif cmd_id == message.type.ping then
		on_ping(port)
	end
end

local function new_follower_role(socket, timer)
	return {
		role = M.role.follower,
		socket = socket,
		heartbeat_timer = timer,
	}
end

---@diagnostic disable-next-line: unused-local
local function on_follower_command(cmd_id, payload) end

local function try_init_leader()
	logger.debug("try_init_leader")
	local socket, err, code = uv.bind_as_server(uv.recv_buf(function(buf, port)
		assert(buf ~= nil, "recv_msg callback with empty data")
		local cmd_id, payload, err = message.unpack_frame(buf)
		if err ~= nil then
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
	if err ~= nil then
		return err, code
	end
	G.role = new_leader_role(socket)
	return nil, nil
end

local function try_init_follower()
	logger.debug("try_init_follower")
	local socket, err, code = uv.bind_as_client(uv.recv_buf(function(buf, port)
		local cmd_id, payload, err = message.unpack_frame(buf)
		if err ~= nil or port ~= G.PORT then
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
	if err ~= nil then
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

-- Capabilities & Roles -------------------------------------------------------
local role_capabilities = {
	leader = {
		[message.type.pong] = true,
		[message.type.task_request] = true,
		[message.type.task_granted] = true,
		[message.type.task_denied] = true,
	},
	follower = {
		[message.type.ping] = true,
		[message.type.task_capable] = true,
	},
}

function M.can_perform_action(role, cmd_id)
	if not role_capabilities[role] then
		return false, "Role not found"
	end
	local caps = role_capabilities[role] or {}
	if caps[cmd_id] then
		return true, nil
	end
	return false, "Action is not allowed"
end

-- Handlers & Dispatch --------------------------------------------------------
G.message_handlers = {}

function M.reset_handlers()
	G.message_handlers = {}
end

function M.register_handler(cmd_id, fn)
	if not G.message_handlers[cmd_id] then
		G.message_handlers[cmd_id] = { fn }
	else
		table.insert(G.message_handlers[cmd_id], fn)
	end
end

function M.perform_action(role, buf)
	local cmd_id, payload, err = M.unpack_frame(buf)
	if err ~= nil then
		return "unpack failed: " .. err
	end

	local allowed, reason = M.can_perform_action(role, cmd_id)
	if not allowed then
		return reason
	end

	local handlers = G.message_handlers[cmd_id]
	if not handlers then
		return "no handlers for " .. cmd_id
	end

	for _, fn in ipairs(handlers) do
		local ok, res = pcall(fn, payload)
		if not ok then
			logger.error("Handler crashed: " .. tostring(res))
			return res
		end
	end
	return nil
end

return M
