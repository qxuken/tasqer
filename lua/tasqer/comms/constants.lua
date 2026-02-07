--- Communication layer constants.
--- @class CommsConstants

local M = {}

-- Heartbeat timeouts (peer detection)
--- @type integer Timeout before considering a peer disconnected (ms)
M.HEARTBEAT_TIMEOUT = 3000
--- @type integer Base interval between heartbeat pings (ms)
M.HEARTBEAT_INTERVAL = 1000
--- @type integer Minimum random jitter added to heartbeat interval (ms)
M.HEARTBEAT_RANGE_FROM = 100
--- @type integer Maximum random jitter added to heartbeat interval (ms)
M.HEARTBEAT_RANGE_TO = 400

-- Task timeouts (fast local operations)
--- @type integer Timeout waiting for capable responses from followers (ms)
M.TASK_DISPATCH_TIMEOUT = 500
--- @type integer Timeout waiting for follower to complete execution (ms)
M.TASK_EXECUTION_TIMEOUT = 1000
--- @type integer Cleanup delay for denied tasks on follower (ms)
M.TASK_DENIED_CLEANUP_TIMEOUT = 2000

-- Issuer timeouts
--- @type integer Timeout before considering a leader disconnected (ms)
M.ISSUER_PING_TIMEOUT = 1000
--- @type integer Base interval between heartbeat pings (ms)
M.ISSUER_PING_INTERVAL = M.ISSUER_PING_TIMEOUT / 2
--- @type integer Timeout before considering a leader unable to complete task (ms)
M.ISSUER_PENDING_TIMEOUT = 200
--- @type integer Timeout before considering a leader unable to complete task (ms)
M.ISSUER_COMPLETION_TIMEOUT = 1000

--- Role identifier constants
--- @enum RoleId
M.role = {
	issuer = -2,
	transition = -1,
	candidate = 0,
	follower = 1,
	leader = 2,
}

--- Task state constants for tracking task lifecycle
--- @enum TaskState
M.task_state = {
	pending = 0, -- Task received, awaiting response
	dispatched = 1, -- Sent to followers, waiting for capable responses
	granted = 2, -- Granted to execute
	in_progress = 3, -- Execution in progress
	completed = 4, -- Successfully completed
	denied = 5, -- Denied, awaiting cleanup
	failed = 6, -- Execution failed
}

return M
