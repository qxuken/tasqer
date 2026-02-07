--- Tests for follower role behavior.
--- Covers: dispatch handling, capability response, execution, denied cleanup.

local G = require("tasqer.G")
local h = require("tests.test_helpers")
local mock_uv = require("tests.mock_uv")
local mock_tasks = require("tests.mock_tasks")
local message = require("tasqer.message.mod")
local c = require("tasqer.comms.constants")

-- ============================================================
-- Scenario: Follower receives dispatch -> capable -> granted -> executes
-- ============================================================

h.suite("follower: happy path")

h.test("dispatch -> capable -> granted -> exec_done", function()
	h.setup_follower()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	local task_id = 42
	h.send_task_dispatch(task_id)

	-- Follower should report capable
	h.assert_sent(message.type.task_capable, nil, "capable sent")
	h.assert_eq(mock_tasks.can_execute_call_count(), 1, "can_execute called")

	-- Task should be stored locally
	h.assert_not_nil(G.role.tasks[task_id], "task stored locally")
	h.assert_eq(G.role.tasks[task_id].state, c.task_state.pending, "task state pending")

	-- Leader grants
	mock_uv.clear_sent_frames()
	h.send_task_granted(task_id)

	-- Should execute and send exec_done
	h.assert_eq(mock_tasks.execute_call_count(), 1, "execute called")
	h.assert_sent(message.type.task_exec_done, nil, "exec_done sent")

	-- Task should be cleaned up
	h.assert_nil(G.role.tasks[task_id], "task cleaned up after exec")
end)

h.test("dispatch -> capable -> granted -> execute fails -> exec_failed", function()
	h.setup_follower()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(false)

	local task_id = 42
	h.send_task_dispatch(task_id)
	h.send_task_granted(task_id)

	h.assert_sent(message.type.task_exec_failed, nil, "exec_failed sent")
	h.assert_nil(G.role.tasks[task_id], "task cleaned up after failure")
end)

-- ============================================================
-- Scenario: Follower not capable
-- ============================================================

h.suite("follower: not capable")

h.test("dispatch -> not capable -> responds not_capable + cleans up task", function()
	h.setup_follower()
	mock_tasks.set_capable(false)

	local task_id = 42
	h.send_task_dispatch(task_id)

	h.assert_sent(message.type.task_not_capable, nil, "not_capable sent")
	h.assert_nil(G.role.tasks[task_id], "task cleaned up when not capable")
	h.assert_eq(mock_tasks.execute_call_count(), 0, "execute should not be called")
end)

-- ============================================================
-- Scenario: Follower receives denied
-- ============================================================

h.suite("follower: denied")

h.test("dispatch -> capable -> denied -> delayed cleanup", function()
	h.setup_follower()
	mock_tasks.set_capable(true)

	local task_id = 42
	h.send_task_dispatch(task_id)

	-- Gets denied instead of granted
	h.send_task_denied(task_id)

	-- Task should exist in denied state
	h.assert_not_nil(G.role.tasks[task_id], "task still exists during cleanup period")
	h.assert_eq(G.role.tasks[task_id].state, c.task_state.denied, "task state is denied")

	-- Fire the cleanup timeout
	local task = G.role.tasks[task_id]
	mock_uv.fire_timer(task.timeout_timer)

	-- Now task should be cleaned up
	h.assert_nil(G.role.tasks[task_id], "task cleaned up after denied timeout")
end)

h.test("denied for unknown task -> no crash", function()
	h.setup_follower()
	-- No task exists locally
	h.send_task_denied(99999)
	-- Just make sure it doesn't error
end)

-- ============================================================
-- Scenario: Follower granted but task missing
-- ============================================================

h.suite("follower: granted edge cases")

h.test("granted but task not found -> sends exec_failed", function()
	h.setup_follower()

	-- Send granted for a task that doesn't exist locally
	h.send_task_granted(99999)

	h.assert_sent(message.type.task_exec_failed, nil, "exec_failed for missing task")
end)

h.test("granted but task not in pending state -> ignored", function()
	h.setup_follower()
	mock_tasks.set_capable(true)

	local task_id = 42
	h.send_task_dispatch(task_id)

	-- Manually change state to something other than pending
	G.role.tasks[task_id].state = c.task_state.in_progress

	mock_uv.clear_sent_frames()
	h.send_task_granted(task_id)

	-- Should not call execute again
	h.assert_eq(mock_tasks.execute_call_count(), 0, "execute not called for non-pending state")
end)

-- ============================================================
-- Scenario: Follower pending timeout
-- ============================================================

h.suite("follower: pending timeout")

h.test("task pending timeout -> task removed locally", function()
	h.setup_follower()
	mock_tasks.set_capable(true)

	local task_id = 42
	h.send_task_dispatch(task_id)

	-- Task exists in pending state
	h.assert_not_nil(G.role.tasks[task_id])
	local task = G.role.tasks[task_id]
	h.assert_not_nil(task.timeout_timer, "pending timeout set")

	-- Fire the pending timeout
	mock_uv.fire_timer(task.timeout_timer)

	-- Task should be cleaned up
	h.assert_nil(G.role.tasks[task_id], "task removed after pending timeout")
end)

h.test("pending timeout does not fire after grant (timer cleared)", function()
	h.setup_follower()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	local task_id = 42
	h.send_task_dispatch(task_id)

	local task = G.role.tasks[task_id]
	local timeout_timer = task.timeout_timer

	-- Grant the task (should clear the pending timeout)
	h.send_task_granted(task_id)

	-- After execution, task is cleaned up
	h.assert_nil(G.role.tasks[task_id], "task cleaned up after execution")

	-- Firing the old timer should be safe (task already gone)
	-- This should not crash
	mock_uv.fire_timer(timeout_timer)
end)

-- ============================================================
-- Scenario: Follower pong handling
-- ============================================================

h.suite("follower: heartbeat")

h.test("pong updates last_pong_time", function()
	h.setup_follower()

	h.assert_nil(G.role.last_pong_time, "initially nil")

	mock_uv.set_time(1000)
	h.send_pong(500)

	h.assert_not_nil(G.role.last_pong_time, "pong time set")
	h.assert_eq(G.role.last_pong_time, 1000, "pong time matches mock uv.now()")
end)

h.test("multiple pongs update correctly", function()
	h.setup_follower()

	mock_uv.set_time(1000)
	h.send_pong(500)
	h.assert_eq(G.role.last_pong_time, 1000)

	mock_uv.set_time(2000)
	h.send_pong(1500)
	h.assert_eq(G.role.last_pong_time, 2000)
end)

-- ============================================================
-- Scenario: Follower last_command_id tracking
-- ============================================================

h.suite("follower: command ID tracking")

h.test("dispatch updates last_command_id to max", function()
	h.setup_follower()
	mock_tasks.set_capable(false)

	G.last_command_id = 5
	h.send_task_dispatch(10)
	h.assert_eq(G.last_command_id, 10, "updated to dispatch task id")
end)

h.test("dispatch does not decrease last_command_id", function()
	h.setup_follower()
	mock_tasks.set_capable(false)

	G.last_command_id = 20
	h.send_task_dispatch(10)
	h.assert_eq(G.last_command_id, 20, "should not decrease")
end)

-- ============================================================
-- Scenario: Follower deferred can_execute
-- ============================================================

h.suite("follower: deferred capability check")

h.test("deferred can_execute callback still works", function()
	h.setup_follower()

	local captured_cb = nil
	mock_tasks.set_can_execute_fn(function(payload, callback)
		captured_cb = callback
	end)

	local task_id = 42
	h.send_task_dispatch(task_id)

	-- Task exists but no message sent yet (callback not invoked)
	h.assert_not_nil(G.role.tasks[task_id])
	h.assert_not_sent(message.type.task_capable, nil, "no capable yet")
	h.assert_not_sent(message.type.task_not_capable, nil, "no not_capable yet")

	-- Now invoke the callback
	captured_cb(true)

	h.assert_sent(message.type.task_capable, nil, "capable sent after deferred callback")
end)

h.test("deferred can_execute after task timeout -> callback ignored", function()
	h.setup_follower()

	local captured_cb = nil
	mock_tasks.set_can_execute_fn(function(payload, callback)
		captured_cb = callback
	end)

	local task_id = 42
	h.send_task_dispatch(task_id)

	-- Fire the pending timeout before callback
	local task = G.role.tasks[task_id]
	mock_uv.fire_timer(task.timeout_timer)
	h.assert_nil(G.role.tasks[task_id], "task removed by timeout")

	-- Now invoke the late callback - should be a no-op
	mock_uv.clear_sent_frames()
	captured_cb(true)

	-- Should not send anything since task was already removed
	h.assert_not_sent(message.type.task_capable, nil, "no message after late callback")
end)

return h.run()
