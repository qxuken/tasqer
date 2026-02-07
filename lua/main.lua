local luv = require("luv")
local uv = require("tasqer.uv_wrapper")
local tasks = require("tasqer.tasks.mod")
local comms = require("tasqer.comms.mod")
local constants = require("tasqer.comms.constants")
local logger = require("tasqer.logger")
local cli = require("tasqer.cli")

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
	os.execute("wezterm cli spawn nvim " .. payload.path)
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
