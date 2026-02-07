--- libuv abstraction wrapper for async I/O operations.
--- Provides a unified interface for UDP sockets, timers, and file operations.
--- @class UvWrapperModule

local G = require("tasqer.G")
local logger = require("tasqer.logger")

--- @class uv_udp_t UDP socket handle
--- @field bind fun(self: uv_udp_t, host: string, port: integer): integer, string?, integer?
--- @field connect fun(self: uv_udp_t, host: string, port: integer): integer, string?, integer?
--- @field recv_start fun(self: uv_udp_t, callback: RecvCallback): integer, string?, integer?
--- @field recv_stop fun(self: uv_udp_t)
--- @field send fun(self: uv_udp_t, data: string, host: string?, port: integer?, callback: fun(err: string?))
--- @field getsockname fun(self: uv_udp_t): UdpAddress
--- @field close fun(self: uv_udp_t)

--- @class uv_timer_t Timer handle
--- @field start fun(self: uv_timer_t, timeout: integer, repeat_ms: integer, callback: fun())
--- @field stop fun(self: uv_timer_t)
--- @field close fun(self: uv_timer_t)

--- @class uv_pipe_t Pipe handle
--- @field close fun(self: uv_pipe_t)

--- @class UdpAddress
--- @field ip string IP address
--- @field port integer Port number

--- @class StatResult
--- @field type string File type ("file", "directory", etc.)
--- @field size integer File size in bytes

--- @alias RecvCallback fun(err: string?, buf: string?, addr: UdpAddress?, flags: table?)
--- @alias DataCallback fun(buf: string, port: integer)
--- @alias ErrorCallback fun(err: string)
--- @alias FstatCallback fun(err: string?, stat: StatResult?)

--- @class UvModule libuv module interface
--- @field new_udp fun(): uv_udp_t
--- @field new_timer fun(): uv_timer_t
--- @field new_pipe fun(): uv_pipe_t
--- @field fs_open fun(path: string, mode: string, flags: integer, callback: fun(err: string?, fd: integer?))
--- @field fs_fstat fun(fd: integer, callback: fun(err: string?, stat: StatResult?))
--- @field fs_close fun(fd: integer, callback: fun(err: string?))
--- @field now fun(): integer
--- @field run fun()
--- @field stop fun()
--- @field shutdown fun(handle: uv_pipe_t, callback: fun())

--- @class UvWrapperModule
--- @field _internal_uv UvModule? The underlying libuv module
local M = { _internal_uv = nil }

--- Initialize the wrapper with a libuv implementation
--- @param uv UvModule The libuv module (luv or vim.uv)
function M.init(uv)
	M._internal_uv = uv
end

--- Get file stats asynchronously
--- @param path string The file path to stat
--- @param callback FstatCallback Callback with (err, stat) result
function M.fstat(path, callback)
	M._internal_uv.fs_open(path, "r", 438, function(fopen_err, fd)
		if fopen_err then
			return callback(fopen_err, nil)
		end
		M._internal_uv.fs_fstat(fd, function(fstat_err, stat)
			M._internal_uv.fs_close(fd, function() end)
			if fstat_err then
				return callback(fstat_err, nil)
			end
			return callback(nil, stat)
		end)
	end)
end

--- Create a receive buffer callback that filters and processes UDP messages
--- @param data_callback DataCallback Called with (buf, port) for valid messages
--- @param error_callback ErrorCallback Called with error string on receive errors
--- @return RecvCallback callback The wrapped callback for recv_start
function M.recv_buf(data_callback, error_callback)
	return function(err, buf, addr, flags)
		if err ~= nil then
			logger.warn("recv_msg -> [err] " .. err)
			error_callback(err)
			return
		end
		if not buf or not addr or addr.ip ~= G.HOST then
			return
		end
		local buf_len = #buf
		if logger.is_trace() then
			logger.trace("[buf]")
			logger.trace("len = " .. buf_len)
			logger.trace(buf)
			logger.trace("[addr]")
			logger.trace_dump(addr)
			if flags ~= nil then
				logger.trace("[flags]")
				logger.trace_dump(flags)
			end
			logger.trace("recv_msg:" .. addr.port .. " -> buf_len = " .. buf_len)
		end

		data_callback(buf, addr.port)
	end
end

--- Bind a UDP socket as a server (leader) on the configured port
--- @param callback RecvCallback Callback for incoming messages
--- @return uv_udp_t? socket The bound socket, or nil on error
--- @return string? err Error message if binding failed
--- @return integer? code Error code if binding failed
function M.bind_as_server(callback)
	local socket = M._internal_uv.new_udp()
	local ret, err, code
	ret, err, code = socket:bind(G.HOST, G.PORT)
	if ret ~= 0 then
		socket:close()
		return nil, err, code
	end
	ret, err, code = socket:recv_start(callback)
	if ret ~= 0 then
		socket:close()
		return nil, err, code
	end
	logger.info("udp server listening on port: " .. G.PORT)
	return socket, nil, nil
end

--- Bind a UDP socket as a client (follower) connected to the leader
--- @param callback RecvCallback Callback for incoming messages
--- @return uv_udp_t? socket The bound socket, or nil on error
--- @return string? err Error message if binding failed
--- @return integer? code Error code if binding failed
function M.bind_as_client(callback)
	local socket = M._internal_uv.new_udp()
	local ret, err, code
	ret, err, code = socket:bind(G.HOST, 0)
	if ret ~= 0 then
		socket:close()
		return nil, err, code
	end
	ret, err, code = socket:connect(G.HOST, G.PORT)
	if ret ~= 0 then
		socket:close()
		return nil, err, code
	end
	ret, err, code = socket:recv_start(callback)
	if ret ~= 0 then
		socket:close()
		return nil, err, code
	end
	logger.info("udp client open on port: " .. socket:getsockname().port)
	return socket, nil, nil
end

--- Stop and close a timer
--- @param timer uv_timer_t The timer to clear
function M.clear_timer(timer)
	if not timer then
		return
	end
	timer:stop()
	timer:close()
end

--- Set a repeating interval timer
--- @param time integer Interval time in milliseconds
--- @param callback fun() Callback to invoke on each interval
--- @param immediately boolean? If true, invoke callback immediately (default: false)
--- @return uv_timer_t timer The created timer handle
function M.set_interval(time, callback, immediately)
	immediately = immediately or false
	local initial = immediately and 0 or time
	local timer = M._internal_uv.new_timer()
	timer:start(initial, time, callback)
	return timer
end

--- Set a one-shot timeout timer
--- @param timeout integer Timeout duration in milliseconds
--- @param callback fun() Callback to invoke when timeout expires
--- @return uv_timer_t timer The created timer handle
function M.set_timeout(timeout, callback)
	local timer = M._internal_uv.new_timer()
	timer:start(timeout, 0, function()
		pcall(M.clear_timer, timer)
		callback()
	end)
	return timer
end

--- Get the current event loop time in milliseconds
--- @return integer time Current time in milliseconds
function M.now()
	return M._internal_uv.now()
end

--- Create a new UDP socket handle
--- @return uv_udp_t socket The new UDP socket
function M.new_udp()
	return M._internal_uv.new_udp()
end

--- Shutdown stdin and invoke callback
--- @param callback fun() Callback to invoke after shutdown
function M.shutdown(callback)
	local stdin = M._internal_uv.new_pipe()
	M._internal_uv.shutdown(stdin, function()
		logger.warn("stdin shutdown")
		callback()
	end)
end

--- Run the event loop
function M.run()
	M._internal_uv.run()
end

--- Stop the event loop
function M.stop()
	M._internal_uv.stop()
end

return M
