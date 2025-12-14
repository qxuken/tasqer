local uv = require("lua.uv_wrapper")
local logger = require("lua.logger")
local comms = require("lua.comms")

logger.set_printer(function(level, message)
	vim.notify(message, level)
end)
uv.init(vim.uv)
comms.run_comms()
