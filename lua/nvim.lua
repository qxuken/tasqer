local uv = require("luv")

local G = {
	trace = false,
	debug = true,
	HOST = "127.0.0.1",
	PORT = 48391,
}

local helpers = {}

function helpers.debug(...)
	if G.debug then
		print(...)
	end
end

function helpers.trace(...)
	if G.trace then
		print(...)
	end
end

function helpers.trace_dump(t, indent, seen)
	if not G.trace or not t then
		return
	end
	indent, seen = indent or "", seen or {}
	if seen[t] then
		print(indent .. "*RECURSION*")
		return
	end
	seen[t] = true
	for k, v in pairs(t) do
		if type(v) == "table" then
			print(("%s[%s] = {"):format(indent, tostring(k)))
			helpers.trace_dump(v, indent .. "  ", seen)
			print(indent .. "}")
		else
			print(("%s[%s] = %s"):format(indent, tostring(k), tostring(v)))
		end
	end
end

function helpers.fstat(path, callback)
	uv.fs_open(path, "r", 438, function(fopen_err, fd)
		if fopen_err then
			return callback(fopen_err, nil)
		end
		uv.fs_fstat(fd, function(fstat_err, stat)
			uv.fs_close(fd, function() end)
			if fstat_err then
				return callback(fstat_err, nil)
			end
			return callback(nil, stat)
		end)
	end)
end

function helpers.bind_as_server(callback)
	local socket = uv.new_udp()
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
	helpers.debug("udp server listening on port: " .. G.PORT)
	return socket, nil, nil
end

function helpers.bind_as_client(callback)
	local socket = uv.new_udp()
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
	helpers.debug("udp client open on port: " .. socket:getsockname().port)
	return socket, nil, nil
end

function helpers.recv_msg(data_callback, error_callback)
	return function(err, data, addr, flags)
		local ip, port
		if err ~= nil then
			helpers.debug("recv_msg -> [err] " .. err)
			error_callback(err)
			return
		end
		if data ~= nil then
			helpers.trace("[data]")
			helpers.trace("len = " .. string.len(data))
			helpers.trace(data)
		end
		if addr ~= nil then
			ip = addr.ip
			port = addr.port

			helpers.trace("[addr]")
			helpers.trace_dump(addr)
		end
		if flags ~= nil then
			helpers.trace("[flags]")
			helpers.trace_dump(flags)
		end

		if port ~= nil then
			helpers.debug(port .. " -> " .. (data ~= nil and data or "nil"))
		end
		data_callback(data, ip, port)
	end
end

local COMMANDS = {
	{
		"open",
		is_possible_to_perform = function(path, callback)
			helpers.fstat(path, function(err, stat)
				callback(not err and stat ~= nil and stat.file == "file")
			end)
		end,
		perform = function(path)
			print("openning " .. path)
			return nil
		end,
	},
}

local candidate = {
	type = "candidate",
}
G.role = candidate
G.commands_queue = {}
G.peers = {}

local comms = {}

function comms.cleanup_role_and_shutdown_socket()
	if not G.role then
		G.role = candidate
		return
	end
	if G.role.type == "candidate" then
		return
	end
	if G.role.type == "leader" then
		G.role.socket:close()
	elseif G.role.type == "follower" then
		G.role.socket:close()
		G.role.timer:stop()
		G.role.timer:close()
	end
	G.role = candidate
end

function comms.try_leader()
	helpers.debug("try_leader")
	local socket, err, code = helpers.bind_as_server(helpers.recv_msg(function(data, ip, port)
		if G.role.type == "leader" and data ~= nil then
			G.role.socket:send(data, ip, port, function(err)
				if err ~= nil then
					helpers.debug(err)
				end
			end)
		end
	end, function(err)
		if err ~= nil then
			comms.run_comms()
		end
	end))
	if err ~= nil then
		return err, code
	end
	G.role = {
		type = "leader",
		socket = socket,
	}
	return nil, nil
end

function comms.try_follower()
	helpers.debug("try_follower")
	local socket, err, code = helpers.bind_as_client(helpers.recv_msg(function(data, ip, port) end, function(err)
		if err ~= nil then
			comms.run_comms()
		end
	end))
	if err ~= nil then
		return err, code
	end
	local timer = uv.new_timer()
	local timer_duration = 1000 + math.random(250, 750)
	helpers.debug("sendings pings per " .. timer_duration .. "ms")
	timer:start(0, timer_duration, function()
		if G.role.type == "follower" then
			G.role.socket:send("ping" .. uv.now(), nil, nil, function(send_err)
				if send_err ~= nil then
					helpers.debug(send_err)
				end
			end)
		end
	end)
	G.role = {
		type = "follower",
		socket = socket,
		timer = timer,
	}
	return nil, nil
end

function comms.run_comms(retries)
	local retries_left = retries and retries - 1 or 3
	helpers.debug("run_comms: " .. retries_left)
	if retries_left == 0 then
		return false, "No more retries, quiting"
	end
	comms.cleanup_role_and_shutdown_socket()
	local err
	err = comms.try_leader()
	if err ~= nil then
		print(err)
		err = comms.try_follower()
		if err ~= nil then
			print(err)
			return comms.run_comms(retries_left)
		end
	end
	return true, nil
end

local stdin = uv.new_pipe()
uv.shutdown(stdin, function()
	print("stdin shutdown", stdin)
	comms.cleanup_role_and_shutdown_socket()
end)

-- Hot Loop

-- if not ok then
-- 	print("Comms failed: " .. err and err or "unknown")
-- end

-- helpers.fstat("lua/nvim.lua", function(err, stat)
-- 	print("lua/nvim.lua")
-- 	print(err)
-- 	if stat then
-- 		utils.dump(stat)
-- 	end
-- end)
-- helpers.fstat("lua/nvim.lu", function(err, stat)
-- 	print("lua/nvim.lua")
-- 	print(err)
-- 	if stat then
-- 		utils.dump(stat)
-- 	end
-- end)

print(comms.run_comms())

uv.run()
