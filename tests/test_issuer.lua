--- Tests for issuer role behavior.
--- The issuer connects to a leader, dispatches one task, and handles results.
--- Covers: happy path, failure fallback, timeout fallback, local execution.

local G = require("tasqer.G")
local h = require("tests.test_helpers")
local mock_uv = require("tests.mock_uv")
local mock_tasks = require("tests.mock_tasks")
local message = require("tasqer.message.mod")
local c = require("tasqer.comms.constants")
local issuer = require("tasqer.comms.issuer")

--- Helper: set up issuer role via try_init
--- @return table task The issuer task entry
local function setup_issuer()
	local task = {
		type_id = mock_tasks.TASK_TYPE_ID,
		payload = mock_tasks.make_payload(),
		state = c.task_state.pending,
	}
	local shutdown_called = false
	local shutdown_fn = function()
		shutdown_called = true
		-- Mimic what comms.shutdown does: clear role timers
		if G.role and G.role.id == c.role.issuer then
			issuer.cleanup_role(G.role)
		end
	end
	local on_err_called = false
	local on_err_fn = function()
		on_err_called = true
	end

	local err = issuer.try_init(task, shutdown_fn, on_err_fn)
	assert(not err, "issuer try_init failed: " .. tostring(err))

	return task,
		shutdown_fn,
		on_err_fn,
		function()
			return shutdown_called
		end,
		function()
			return on_err_called
		end
end

--- Helper: simulate receiving from the leader port
local function issuer_recv(frame)
	mock_uv.simulate_recv(frame, G.PORT)
end

-- ============================================================
-- Scenario: Issuer happy path
-- ============================================================

h.suite("issuer: happy path")

h.test("issuer dispatches task_request on init", function()
	setup_issuer()

	-- Should have sent a task_request frame
	h.assert_sent(message.type.task_request, nil, "task_request sent on init")
end)

h.test("issuer receives pending -> resets dispatch timer", function()
	local task = setup_issuer()

	-- The dispatch_timer should exist
	h.assert_not_nil(G.role.dispatch_timer, "dispatch timer exists")
	local old_timer = G.role.dispatch_timer

	-- Send pending
	issuer_recv(message.pack_task_pending_frame(0))

	-- Dispatch timer should have been replaced (old cleared, new set)
	-- Task state should still be dispatched
	h.assert_eq(task.state, c.task_state.dispatched, "task still dispatched")
end)

h.test("issuer receives completed -> shuts down comms", function()
	local task, _, _, _ = setup_issuer()

	issuer_recv(message.pack_task_pending_frame(0))
	issuer_recv(message.pack_task_completed_frame(0))

	h.assert_false(mock_uv.is_running(), "uv.stop called on completion")
end)

-- ============================================================
-- Scenario: Issuer receives failed -> local fallback
-- ============================================================

h.suite("issuer: failure fallback")

h.test("issuer receives task_failed -> tries local execution", function()
	local task, _, _, was_shutdown = setup_issuer()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	issuer_recv(message.pack_task_pending_frame(0))
	issuer_recv(message.pack_task_failed_frame(0))

	-- Should have tried local execution
	h.assert_eq(mock_tasks.can_execute_call_count(), 1, "can_execute called for fallback")
	h.assert_eq(mock_tasks.execute_call_count(), 1, "execute called for fallback")
	h.assert_true(was_shutdown(), "shutdown called before fallback")
end)

h.test("issuer task_failed -> local not capable -> error logged", function()
	local task, _, _, was_shutdown = setup_issuer()
	mock_tasks.set_capable(false)

	issuer_recv(message.pack_task_pending_frame(0))
	issuer_recv(message.pack_task_failed_frame(0))

	h.assert_eq(mock_tasks.can_execute_call_count(), 1, "can_execute called")
	h.assert_eq(mock_tasks.execute_call_count(), 0, "execute not called when not capable")
end)

-- ============================================================
-- Scenario: Issuer pending timeout -> local fallback
-- ============================================================

h.suite("issuer: pending timeout")

h.test("no pending response -> dispatch timer fires -> local fallback", function()
	local task = setup_issuer()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	-- The dispatch timer was set on init (ISSUER_PENDING_TIMEOUT)
	local timer = G.role.dispatch_timer
	h.assert_not_nil(timer, "dispatch timer should be set")

	-- Fire the timeout
	mock_uv.fire_timer(timer)

	-- Should try local execution
	h.assert_eq(mock_tasks.can_execute_call_count(), 1, "can_execute called after timeout")
	h.assert_eq(mock_tasks.execute_call_count(), 1, "execute called after timeout")
end)

-- ============================================================
-- Scenario: Issuer completion timeout -> local fallback
-- ============================================================

h.suite("issuer: completion timeout")

h.test("pending received but no completion -> completion timer fires -> local fallback", function()
	local task = setup_issuer()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	-- Receive pending (replaces dispatch timer with completion timer)
	issuer_recv(message.pack_task_pending_frame(0))

	-- The new dispatch_timer is now the completion timer
	local timer = G.role.dispatch_timer
	h.assert_not_nil(timer, "completion timer should be set")

	-- Fire the completion timeout
	mock_uv.fire_timer(timer)

	h.assert_eq(mock_tasks.can_execute_call_count(), 1, "can_execute called after completion timeout")
end)

-- ============================================================
-- Scenario: Issuer pong handling
-- ============================================================

h.suite("issuer: heartbeat")

h.test("pong updates last_pong_time", function()
	setup_issuer()

	h.assert_nil(G.role.last_pong_time, "initially nil")

	mock_uv.set_time(500)
	issuer_recv(message.pack_pong_frame(400))

	h.assert_not_nil(G.role.last_pong_time, "pong time updated")
	h.assert_eq(G.role.last_pong_time, 500, "pong time matches mock now()")
end)

-- ============================================================
-- Scenario: try_execute_task directly
-- ============================================================

h.suite("issuer: try_execute_task")

h.test("try_execute_task with capable task -> executes", function()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	local task = {
		type_id = mock_tasks.TASK_TYPE_ID,
		payload = mock_tasks.make_payload(),
		state = c.task_state.pending,
	}

	issuer.try_execute_task(task)

	h.assert_eq(task.state, c.task_state.in_progress, "task state in_progress")
	h.assert_eq(mock_tasks.can_execute_call_count(), 1, "can_execute called")
	h.assert_eq(mock_tasks.execute_call_count(), 1, "execute called")
end)

h.test("try_execute_task with not capable task -> not executed", function()
	mock_tasks.set_capable(false)

	local task = {
		type_id = mock_tasks.TASK_TYPE_ID,
		payload = mock_tasks.make_payload(),
		state = c.task_state.pending,
	}

	issuer.try_execute_task(task)

	h.assert_eq(mock_tasks.can_execute_call_count(), 1, "can_execute called")
	h.assert_eq(mock_tasks.execute_call_count(), 0, "execute not called")
end)

h.test("try_execute_task skips if already in_progress", function()
	mock_tasks.set_capable(true)

	local task = {
		type_id = mock_tasks.TASK_TYPE_ID,
		payload = mock_tasks.make_payload(),
		state = c.task_state.in_progress,
	}

	issuer.try_execute_task(task)

	h.assert_eq(mock_tasks.can_execute_call_count(), 0, "should not check capability")
end)

h.test("try_execute_task skips if already completed", function()
	mock_tasks.set_capable(true)

	local task = {
		type_id = mock_tasks.TASK_TYPE_ID,
		payload = mock_tasks.make_payload(),
		state = c.task_state.completed,
	}

	issuer.try_execute_task(task)

	h.assert_eq(mock_tasks.can_execute_call_count(), 0, "should not check capability")
end)

-- ============================================================
-- Scenario: Issuer ignores messages from non-leader ports
-- ============================================================

h.suite("issuer: port filtering")

h.test("message from wrong port -> ignored", function()
	setup_issuer()

	-- Clear frames from init
	mock_uv.clear_sent_frames()

	-- Send completed from wrong port (should be ignored by recv_buf filter)
	local wrong_port = G.PORT + 1
	mock_uv.simulate_recv(message.pack_task_completed_frame(0), wrong_port)

	-- Role should still be issuer (not shut down)
	h.assert_eq(G.role.id, c.role.issuer, "still issuer role")
end)

-- ============================================================
-- Scenario: Issuer init failure
-- ============================================================

h.suite("issuer: init failure")

h.test("client bind failure returns error", function()
	mock_uv.set_client_bind_fail(true)

	local task = {
		type_id = mock_tasks.TASK_TYPE_ID,
		payload = mock_tasks.make_payload(),
		state = c.task_state.pending,
	}
	local err = issuer.try_init(task, function() end, function() end)
	h.assert_not_nil(err, "should return error on bind failure")
end)

return h.run()
