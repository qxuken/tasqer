--- Mock uv_wrapper module for testing.
--- Provides fake timers, sockets, and frame capture.
--- All callbacks are synchronous and manually triggered.

local M = {}

--- Internal state - reset between tests
local _state = {}

function M.reset()
	_state = {
		is_running = true,
		current_time = 0,
		next_timer_id = 1,
		timers = {}, -- id -> { ms, callback, repeat_ms, active }
		server_socket = nil,
		client_sockets = {},
		sent_frames = {}, -- { {frame, host, port} ... }
		recv_callback = nil,
		error_callback = nil,
		bind_server_fail = false,
		bind_client_fail = false,
	}
end

M.reset()

--- Get all frames sent to a specific port
--- @param port integer
--- @return table[] frames
function M.get_frames_to_port(port)
	local result = {}
	for _, entry in ipairs(_state.sent_frames) do
		if entry.port == port then
			table.insert(result, entry)
		end
	end
	return result
end

--- Get all sent frames
function M.get_all_sent_frames()
	return _state.sent_frames
end

--- Clear sent frames log
function M.clear_sent_frames()
	_state.sent_frames = {}
end

--- Get timer by handle id
function M.get_timer(handle)
	if type(handle) == "table" and handle._timer_id then
		return _state.timers[handle._timer_id]
	end
	return nil
end

--- Fire a specific timer's callback manually
function M.fire_timer(handle)
	local t = M.get_timer(handle)
	if t and t.active then
		t.callback()
	end
end

--- Fire all timers that have expired at current_time
--- @param advance_ms integer? Optional ms to advance before checking
function M.tick(advance_ms)
	if advance_ms then
		_state.current_time = _state.current_time + advance_ms
	end
	-- Collect timers to fire (snapshot to avoid mutation during iteration)
	local to_fire = {}
	for id, t in pairs(_state.timers) do
		if t.active and t.due_at <= _state.current_time then
			table.insert(to_fire, { id = id, timer = t })
		end
	end
	for _, entry in ipairs(to_fire) do
		local t = entry.timer
		if t.active then
			if t.repeat_ms > 0 then
				t.due_at = _state.current_time + t.repeat_ms
			else
				t.active = false
			end
			t.callback()
		end
	end
end

--- Simulate receiving a UDP buffer from a port
--- @param buf string The raw buffer
--- @param port integer The sender port
function M.simulate_recv(buf, port)
	if _state.recv_callback then
		_state.recv_callback(nil, buf, { ip = "127.0.0.1", port = port }, nil)
	end
end

--- Simulate a receive error
function M.simulate_recv_error(err_msg)
	if _state.recv_callback then
		_state.recv_callback(err_msg, nil, nil, nil)
	end
end

--- Configure server bind to fail
function M.set_server_bind_fail(fail)
	_state.bind_server_fail = fail
end

--- Configure client bind to fail
function M.set_client_bind_fail(fail)
	_state.bind_client_fail = fail
end

-- ============================================================
-- Mock timer handle
-- ============================================================

local function new_timer_handle(id)
	return {
		_timer_id = id,
		_closed = false,
		start = function(self, timeout, repeat_ms, callback)
			local timer = _state.timers[self._timer_id]
			if timer then
				timer.ms = timeout
				timer.repeat_ms = repeat_ms
				timer.callback = callback
				timer.active = true
				timer.due_at = _state.current_time + timeout
			end
		end,
		stop = function(self)
			local timer = _state.timers[self._timer_id]
			if timer then
				timer.active = false
			end
		end,
		close = function(self)
			self._closed = true
			_state.timers[self._timer_id] = nil
		end,
	}
end

-- ============================================================
-- Mock socket handle
-- ============================================================

local function new_mock_socket(is_server)
	local sock = {
		_is_server = is_server,
		_bound = false,
		_connected = false,
		_recv_started = false,
		_closed = false,
		_bound_port = 0,
	}

	function sock:bind(host, port)
		if _state.bind_server_fail and is_server then
			return -1, "EADDRINUSE", -4091
		end
		if _state.bind_client_fail and not is_server then
			return -1, "EADDRINUSE", -4091
		end
		self._bound = true
		self._bound_port = port == 0 and (50000 + math.random(1000)) or port
		return 0, nil, nil
	end

	function sock:connect(host, port)
		self._connected = true
		return 0, nil, nil
	end

	function sock:recv_start(callback)
		self._recv_started = true
		-- Store the raw recv callback (the one from uv.recv_buf wrapper)
		_state.recv_callback = callback
		return 0, nil, nil
	end

	function sock:recv_stop()
		self._recv_started = false
	end

	function sock:send(frame, host, port, callback)
		table.insert(_state.sent_frames, {
			frame = frame,
			host = host,
			port = port,
		})
		if callback then
			callback(nil) -- success
		end
	end

	function sock:getsockname()
		return { ip = "127.0.0.1", port = self._bound_port }
	end

	function sock:close()
		self._closed = true
	end

	return sock
end

-- ============================================================
-- uv_wrapper compatible API
-- ============================================================

local _internal_uv

--- The mock "internal uv" that gets passed to uv_wrapper.init()
_internal_uv = {
	new_udp = function()
		return new_mock_socket(false)
	end,
	new_timer = function()
		local id = _state.next_timer_id
		_state.next_timer_id = id + 1
		local handle = new_timer_handle(id)
		_state.timers[id] = {
			ms = 0,
			repeat_ms = 0,
			callback = function() end,
			active = false,
			due_at = 0,
		}
		return handle
	end,
	new_pipe = function()
		return {
			close = function() end,
		}
	end,
	now = function()
		return _state.current_time
	end,
	run = function() end,
	stop = function()
		_state.is_running = false
	end,
	shutdown = function(handle, callback)
		callback()
	end,
	fs_open = function(path, mode, flags, callback)
		callback(nil, 1)
	end,
	fs_fstat = function(fd, callback)
		callback(nil, { type = "file", size = 100 })
	end,
	fs_close = function(fd, callback)
		callback(nil)
	end,
}

--- Install mock into the uv_wrapper module
function M.install()
	local uv = require("tasqer.uv_wrapper")
	uv.init(_internal_uv)
end

--- Advance mock time without firing timers
function M.set_time(ms)
	_state.current_time = ms
end

--- Get current mock time
function M.get_time()
	return _state.current_time
end

--- Checks if uv was stopped
function M.is_running()
	return _state.is_running
end

return M
