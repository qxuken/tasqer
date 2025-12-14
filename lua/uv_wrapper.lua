local G = require("lua.G")
local logger = require("lua.logger")

local M = { _internal_uv = nil }
function M.init(uv)
	M._internal_uv = uv
end

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
		logger.trace("[buf]")
		logger.trace("len = " .. buf_len)
		logger.trace(buf)
		logger.trace("[addr]")
		logger.trace_dump(addr)
		if flags ~= nil then
			logger.trace("[flags]")
			logger.trace_dump(flags)
		end

		logger.debug("recv_msg:" .. addr.port .. " -> buf_len = " .. buf_len)
		logger.trace(buf)

		data_callback(buf, addr.port)
	end
end

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

function M.clear_interval(timer)
	timer:stop()
	timer:close()
end

function M.set_interval(time, callback, immediately)
	immediately = immediately or false
	local initial = immediately and 0 or time
	local timer = M._internal_uv.new_timer()
	timer:start(initial, time, callback)
	return timer
end

function M.set_timeout(timeout, callback)
	local timer = M._internal_uv.new_timer()
	timer:start(timeout, 0, function()
		M.clear_interval(timer)
		callback()
	end)
	return timer
end

function M.now()
	return M._internal_uv.now()
end

function M.shutdown(callback)
	local stdin = M._internal_uv.new_pipe()
	M._internal_uv.shutdown(stdin, function()
		logger.warn("stdin shutdown")
		callback()
	end)
end

function M.run()
	M._internal_uv.run()
end

return M
