local luv = require("luv")
local uv = require("tasqer.uv_wrapper")
local tasks = require("tasqer.tasks.mod")
local comms = require("tasqer.comms.mod")
local constants = require("tasqer.comms.constants")
local logger = require("tasqer.logger")
local cli = require("cli")

math.randomseed(os.time())

uv.init(luv)
local sigint = luv.new_signal()
luv.signal_start(sigint, "sigint", function()
	print("SIGINT, shutting down...")
	luv.stop()
end)

tasks.register(require("tasqer.tasks.openfile").setup(function(payload, callback)
	uv.fstat(payload.path, function(err, stat)
		local capable = not err and stat and stat.type == "file"
		if not capable then
			logger.warn("Not a file")
		end
		callback(capable)
	end)
end, function(payload, callback)
	local exe = "wezterm"
	if os.getenv("WSL_DISTRO_NAME") ~= nil or os.getenv("OS") == "Windows_NT" then
		exe = "wezterm.exe"
	end
	local args = { "start" }
	local cwd = luv.cwd()
	if cwd and cwd ~= "/" then
		table.insert(args, "--cwd")
		table.insert(args, cwd)
	end

	table.insert(args, "nvim")
	if payload.row > 1 or payload.col > 1 then
		local row = math.max(payload.row, 1)
		local col = math.max(payload.col, 1)
		table.insert(args, string.format([[+"call cursor(%d,%d)"]], row, col))
	end
	table.insert(args, payload.path)

	logger.debug("Executing command: " .. exe .. " " .. table.concat(args, " "))
	--- TODO: Focus window afteer app start
	local handle, pid = luv.spawn(exe, {
		args = args,
		detached = true,
		stdio = { nil, nil, nil }, -- ignore stdin/out/err
	}, function(code, signal)
		if code ~= 0 then
			logger.error("Failed to execute command " .. code .. " " .. signal)
		else
			logger.info("Command executed successfully")
		end
	end)
	handle:unref()
	logger.debug("Command executed: " .. pid)
	callback(true)
end))

local type_id, payload = cli.parse_args()
if type_id == cli.task_types.serve then
	comms.run_comms()
else
	comms.run_task({
		type_id = type_id,
		payload = payload or {},
		state = constants.task_state.pending,
	})
end
uv.shutdown(comms.shutdown)
uv.run()
