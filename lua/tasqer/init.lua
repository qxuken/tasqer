--- Tasqer - Neovim plugin for leader-follower task coordination.
--- Provides setup/register/start API for configuring and running
--- the communication layer within Neovim.

--- @class TasqerConfig
--- @field log_level? integer Log level: 0=TRACE, 1=DEBUG, 2=INFO, 3=WARN, 4=ERROR (default: 1)
--- @field host? string UDP host address (default: "127.0.0.1")
--- @field port? integer UDP port for leader (default: 48391)
--- @field log? fun(level: LogLevel, message: string) Replace default logger

local G = require("tasqer.G")
local uv = require("tasqer.uv_wrapper")
local comms = require("tasqer.comms.mod")
local logger = require("tasqer.logger")

local M = {}

--- @type TasqerConfig
M.defaults = {
	log_level = 3,
	host = "127.0.0.1",
	port = 48391,
	log = function(level, message)
		vim.notify(message, level, {
			name = "tasqer",
		})
	end,
}

--- Initialize tasqer infrastructure: global state, logger, and uv wrapper.
--- Call this before register() and start().
--- @param opts? TasqerConfig Configuration options (merged with defaults)
function M.setup(opts)
	---@type TasqerConfig
	opts = vim.tbl_deep_extend("force", M.defaults, opts or {})

	G.log_level = opts.log_level
	G.HOST = opts.host
	G.PORT = opts.port

	logger.set_printer(opts.log)

	uv.init(vim.uv)
end

--- Register a task module. Call after setup(), before start().
--- @param task TaskModule The task module to register
function M.register(task)
	require("tasqer.tasks.mod").register(task)
end

--- Start the communication layer. Call after setup() and all register() calls.
function M.start()
	comms.run_comms()
	uv.shutdown(comms.shutdown)
end

--- Convenience: register the openfile task with wezterm pane activation.
--- Opens files in current Neovim instance, positions cursor, and
--- activates the wezterm pane. Call after setup(), before start().
function M.setup_wezterm_tasks()
	local openfile = require("tasqer.tasks.openfile")

	M.register(openfile.setup(function(payload, callback)
		local path = vim.fn.fnamemodify(payload.path, ":.")
		uv.fstat(path, function(err, stat)
			callback(not err and stat and stat.type == "file")
		end)
	end, function(payload, callback)
		vim.schedule(function()
			vim.cmd("edit " .. payload.path)
			if payload.row > 0 or payload.col > 0 then
				local row = math.max(payload.row, 1)
				local col = math.max(payload.col, 1)
				vim.cmd("call cursor(" .. row .. "," .. col .. ")")
			end
			vim.system({ "wezterm", "cli", "activate-pane" })
			callback(true)
		end)
	end))
end

return M
