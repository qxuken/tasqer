local uv = require("lua.uv_wrapper")
local comms = require("lua.comms")

uv.init(require("luv"))
uv.shutdown(comms.cleanup_role_and_shutdown_socket)

comms.run_comms()
uv.run()
