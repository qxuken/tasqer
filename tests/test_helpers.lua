--- Minimal self-contained test runner and assertion helpers.
--- No external dependencies required.

local G = require("tasqer.G")
local mock_uv = require("tests.mock_uv")
local mock_tasks = require("tests.mock_tasks")
local message = require("tasqer.message.mod")
local c = require("tasqer.comms.constants")

local M = {}

-- ============================================================
-- Test runner state
-- ============================================================

local _tests = {}
local _current_suite = ""
local _pass_count = 0
local _fail_count = 0
local _failures = {}

--- Register a test
function M.test(name, fn)
	table.insert(_tests, { name = _current_suite .. " > " .. name, fn = fn })
end

--- Set the current test suite name
function M.suite(name)
	_current_suite = name
end

--- Run all registered tests and print results
function M.run()
	_pass_count = 0
	_fail_count = 0
	_failures = {}

	for _, t in ipairs(_tests) do
		-- Reset all state before each test
		M.reset_all()

		local ok, err = pcall(t.fn)
		if ok then
			_pass_count = _pass_count + 1
			io.write("  PASS: " .. t.name .. "\n")
		else
			_fail_count = _fail_count + 1
			table.insert(_failures, { name = t.name, err = err })
			io.write("  FAIL: " .. t.name .. "\n")
			io.write("        " .. tostring(err) .. "\n")
		end
	end

	io.write("\n")
	io.write(string.format("Results: %d passed, %d failed, %d total\n", _pass_count, _fail_count, #_tests))

	if #_failures > 0 then
		io.write("\nFailures:\n")
		for _, f in ipairs(_failures) do
			io.write("  " .. f.name .. "\n")
			io.write("    " .. tostring(f.err) .. "\n")
		end
	end

	-- Clear tests for next file
	_tests = {}
	_current_suite = ""

	return _fail_count
end

-- ============================================================
-- State reset
-- ============================================================

--- Reset everything between tests
function M.reset_all()
	-- Reset G to defaults
	G.log_level = 3 -- WARN only during tests to reduce noise
	G.HOST = "127.0.0.1"
	G.PORT = 48391
	G.command_registry = {}
	G.print = function() end
	G.role = { id = c.role.candidate }
	G.last_command_id = 0

	-- Reset mocks
	mock_uv.reset()
	mock_uv.install()
	mock_tasks.reset()
	mock_tasks.register()
end

-- ============================================================
-- Leader test helpers
-- ============================================================

--- Set up G.role as a leader via the real try_init path
--- This wires up the actual recv callback chain so simulate_recv works
function M.setup_leader()
	local leader = require("tasqer.comms.leader")
	local err = leader.try_init(function() end)
	assert(not err, "Failed to init leader: " .. tostring(err))
	return G.role.socket
end

--- Add a fake peer to the leader's peer list
function M.add_peer(port)
	local uv = require("tasqer.uv_wrapper")
	G.role.peers[port] = uv.set_timeout(c.HEARTBEAT_TIMEOUT, function()
		G.role.peers[port] = nil
	end)
end

--- Simulate the leader receiving a raw buffer from a port
--- (bypasses socket, calls the leader's on_command via frame decode)
function M.leader_recv(buf, port)
	mock_uv.simulate_recv(buf, port)
end

--- Build and send a task_request to the leader from a given port
--- @return string raw_frame The frame that was sent (for reference)
function M.send_task_request(requester_port, task_id, payload)
	payload = payload or mock_tasks.make_payload()
	local raw_data = mock_tasks.encode_payload(payload)
	local frame = message.pack_task_request_frame(task_id or 0, mock_tasks.TASK_TYPE_ID, raw_data)
	M.leader_recv(frame, requester_port)
	return frame
end

--- Build and send a task_capable response to the leader
function M.send_task_capable(follower_port, task_id)
	local frame = message.pack_task_capable_frame(task_id)
	M.leader_recv(frame, follower_port)
end

--- Build and send a task_not_capable response to the leader
function M.send_task_not_capable(follower_port, task_id)
	local frame = message.pack_task_not_capable_frame(task_id)
	M.leader_recv(frame, follower_port)
end

--- Build and send a task_exec_done to the leader
function M.send_task_exec_done(follower_port, task_id)
	local frame = message.pack_task_exec_done_frame(task_id)
	M.leader_recv(frame, follower_port)
end

--- Build and send a task_exec_failed to the leader
function M.send_task_exec_failed(follower_port, task_id)
	local frame = message.pack_task_exec_failed_frame(task_id)
	M.leader_recv(frame, follower_port)
end

--- Build and send a ping to the leader
function M.send_ping(follower_port)
	local frame = message.pack_ping_frame(mock_uv.get_time())
	M.leader_recv(frame, follower_port)
end

-- ============================================================
-- Follower test helpers
-- ============================================================

--- Set up G.role as a follower via the real try_init path
--- This wires up the actual recv callback chain so simulate_recv works
function M.setup_follower()
	-- Leader must be "already bound" so follower bind succeeds on a different port
	-- The mock always succeeds for client bind, so this just works
	local follower = require("tasqer.comms.follower")
	local err = follower.try_init(function() end)
	assert(not err, "Failed to init follower: " .. tostring(err))
	return G.role.socket
end

--- Simulate the follower receiving a raw buffer from the leader port
function M.follower_recv(buf)
	mock_uv.simulate_recv(buf, G.PORT)
end

--- Send a task_dispatch to the follower
function M.send_task_dispatch(task_id, payload)
	payload = payload or mock_tasks.make_payload()
	local raw_data = mock_tasks.encode_payload(payload)
	local frame = message.pack_task_dispatch_frame(task_id, mock_tasks.TASK_TYPE_ID, raw_data)
	M.follower_recv(frame)
end

--- Send a task_granted to the follower
function M.send_task_granted(task_id)
	local frame = message.pack_task_granted_frame(task_id)
	M.follower_recv(frame)
end

--- Send a task_denied to the follower
function M.send_task_denied(task_id)
	local frame = message.pack_task_denied_frame(task_id)
	M.follower_recv(frame)
end

--- Send a pong to the follower
function M.send_pong(ts)
	local frame = message.pack_pong_frame(ts or mock_uv.get_time())
	M.follower_recv(frame)
end

-- ============================================================
-- Frame analysis helpers
-- ============================================================

--- Decode a sent frame entry to get message type and payload
function M.decode_sent_frame(entry)
	if not entry or not entry.frame then
		return nil, nil, "no frame"
	end
	return message.unpack_frame(entry.frame)
end

--- Find sent frames matching a message type to a specific port
function M.find_sent_messages(msg_type, port)
	local results = {}
	local frames = port and mock_uv.get_frames_to_port(port) or mock_uv.get_all_sent_frames()
	for _, entry in ipairs(frames) do
		local mt, payload, err = message.unpack_frame(entry.frame)
		if mt == msg_type then
			table.insert(results, { msg_type = mt, payload = payload, port = entry.port })
		end
	end
	return results
end

--- Assert that a specific message type was sent to a port
function M.assert_sent(msg_type, port, msg)
	local found = M.find_sent_messages(msg_type, port)
	assert(
		#found > 0,
		(msg or "")
			.. " Expected "
			.. message.get_name(msg_type)
			.. " to port "
			.. tostring(port)
			.. " but found "
			.. #found
			.. " messages. Total sent: "
			.. #mock_uv.get_all_sent_frames()
	)
	return found
end

--- Assert that a specific message type was NOT sent to a port
function M.assert_not_sent(msg_type, port, msg)
	local found = M.find_sent_messages(msg_type, port)
	assert(
		#found == 0,
		(msg or "")
			.. " Expected NO "
			.. message.get_name(msg_type)
			.. " to port "
			.. tostring(port)
			.. " but found "
			.. #found
	)
end

--- Assert that exactly N messages of a type were sent to a port
function M.assert_sent_count(msg_type, port, count, msg)
	local found = M.find_sent_messages(msg_type, port)
	assert(
		#found == count,
		(msg or "")
			.. " Expected "
			.. count
			.. " "
			.. message.get_name(msg_type)
			.. " to port "
			.. tostring(port)
			.. " but found "
			.. #found
	)
end

--- Assert count of message type sent to any port
function M.assert_total_sent_count(msg_type, count, msg)
	local found = M.find_sent_messages(msg_type)
	assert(
		#found == count,
		(msg or "") .. " Expected " .. count .. " total " .. message.get_name(msg_type) .. " but found " .. #found
	)
end

-- ============================================================
-- General assertions
-- ============================================================

function M.assert_eq(a, b, msg)
	if a ~= b then
		error((msg or "assert_eq") .. ": expected " .. tostring(b) .. " got " .. tostring(a), 2)
	end
end

function M.assert_ne(a, b, msg)
	if a == b then
		error((msg or "assert_ne") .. ": expected not " .. tostring(b) .. " but got " .. tostring(a), 2)
	end
end

function M.assert_true(val, msg)
	if not val then
		error((msg or "assert_true") .. ": expected truthy, got " .. tostring(val), 2)
	end
end

function M.assert_false(val, msg)
	if val then
		error((msg or "assert_false") .. ": expected falsy, got " .. tostring(val), 2)
	end
end

function M.assert_nil(val, msg)
	if val ~= nil then
		error((msg or "assert_nil") .. ": expected nil, got " .. tostring(val), 2)
	end
end

function M.assert_not_nil(val, msg)
	if val == nil then
		error((msg or "assert_not_nil") .. ": expected non-nil", 2)
	end
end

return M
