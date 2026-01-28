--- Main entry point for standalone Lua execution.
--- Initializes the communication layer and starts the event loop.
--- Uses luv (libuv bindings) for async I/O.

local luv = require("luv")
local uv = require("lua.uv_wrapper")
local tasks = require("lua.tasks.mod")
local comms = require("lua.comms.mod")

-- Initialize libuv wrapper with luv module
uv.init(luv)
-- Register shutdown handler to clean up connections
uv.shutdown(comms.cleanup_role_and_shutdown_socket)

local sigint = luv.new_signal()
luv.signal_start(sigint, "sigint", function(signal)
	print("SIGINT, shutting down...")
	luv.stop()
end)

-- Setup task registry and initialize communication
math.randomseed()
tasks.setup()
comms.run_comms()
-- Start the event loop
uv.run()
