--- Tests for leader role task handling.
--- Covers: local execution, follower dispatch, failover, edge cases.

local G = require("tasqer.G")
local h = require("tests.test_helpers")
local mock_uv = require("tests.mock_uv")
local mock_tasks = require("tests.mock_tasks")
local message = require("tasqer.message.mod")
local c = require("tasqer.comms.constants")

local REQUESTER = 50001
local FOLLOWER_A = 50010
local FOLLOWER_B = 50011
local FOLLOWER_C = 50012

-- ============================================================
-- Scenario 1: Leader capable -> leader executes locally
-- ============================================================

h.suite("leader: local execution")

h.test("leader capable -> sends pending + completed to requester", function()
	h.setup_leader()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	h.send_task_request(REQUESTER, 0)

	-- Should have sent task_pending and task_completed to requester
	h.assert_sent(message.type.task_pending, REQUESTER, "pending")
	h.assert_sent(message.type.task_completed, REQUESTER, "completed")

	-- Should have called can_execute and execute
	h.assert_eq(mock_tasks.can_execute_call_count(), 1, "can_execute calls")
	h.assert_eq(mock_tasks.execute_call_count(), 1, "execute calls")

	-- Task should be cleaned up
	local task_count = 0
	for _ in pairs(G.role.tasks) do
		task_count = task_count + 1
	end
	h.assert_eq(task_count, 0, "tasks should be empty after completion")
end)

h.test("leader capable but execute fails -> dispatches to followers", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)

	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(false)

	h.send_task_request(REQUESTER, 0)

	-- Should still send pending
	h.assert_sent(message.type.task_pending, REQUESTER, "pending")

	-- Execution failed, so should dispatch to followers
	h.assert_sent(message.type.task_dispatch, FOLLOWER_A, "dispatch to follower")
end)

h.test("leader capable, execute succeeds -> no dispatch to followers", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)

	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	h.send_task_request(REQUESTER, 0)

	h.assert_not_sent(message.type.task_dispatch, FOLLOWER_A, "should not dispatch")
end)

-- ============================================================
-- Scenario 2: Leader not capable -> dispatch to followers
-- ============================================================

h.suite("leader: dispatch to followers")

h.test("leader not capable -> dispatches to all peers", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	h.assert_sent(message.type.task_pending, REQUESTER, "pending")
	h.assert_sent(message.type.task_dispatch, FOLLOWER_A, "dispatch to A")
	h.assert_sent(message.type.task_dispatch, FOLLOWER_B, "dispatch to B")
end)

h.test("leader not capable, follower capable -> grants first capable", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	-- Task should be in dispatched state
	local task_id = G.last_command_id
	h.assert_eq(G.role.tasks[task_id].state, c.task_state.dispatched)

	-- Follower A reports capable
	h.send_task_capable(FOLLOWER_A, task_id)

	-- Should grant to follower A
	h.assert_sent(message.type.task_granted, FOLLOWER_A, "grant to A")
end)

h.test("follower capable -> exec_done -> completed to requester", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id
	h.send_task_capable(FOLLOWER_A, task_id)
	h.send_task_exec_done(FOLLOWER_A, task_id)

	h.assert_sent(message.type.task_completed, REQUESTER, "completed")
end)

h.test("leader not capable, no peers -> immediate task_failed", function()
	h.setup_leader()
	-- No peers added

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	h.assert_sent(message.type.task_failed, REQUESTER, "failed - no peers")
end)

h.test("requester port excluded from dispatch broadcast", function()
	h.setup_leader()
	-- Add requester as a peer too
	h.add_peer(REQUESTER)
	h.add_peer(FOLLOWER_A)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	-- Should dispatch to FOLLOWER_A but not to REQUESTER
	h.assert_sent(message.type.task_dispatch, FOLLOWER_A, "dispatch to follower")
	h.assert_not_sent(message.type.task_dispatch, REQUESTER, "should not dispatch to requester")
end)

-- ============================================================
-- Scenario 3: All followers not capable -> task_failed
-- ============================================================

h.suite("leader: all followers not capable")

h.test("all followers report not capable -> task_failed to requester", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id
	h.send_task_not_capable(FOLLOWER_A, task_id)
	h.send_task_not_capable(FOLLOWER_B, task_id)

	h.assert_sent(message.type.task_failed, REQUESTER, "failed - all not capable")
end)

h.test("partial not_capable does not trigger failure", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id
	-- Only one reports not capable
	h.send_task_not_capable(FOLLOWER_A, task_id)

	-- Should not have sent task_failed yet
	h.assert_not_sent(message.type.task_failed, REQUESTER, "not failed yet")
end)

h.test("dispatch timeout fires -> task_failed to requester", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id
	local task = G.role.tasks[task_id]
	h.assert_not_nil(task, "task should exist")
	h.assert_not_nil(task.timeout_timer, "timeout timer should be set")

	-- Fire the dispatch timeout
	mock_uv.fire_timer(task.timeout_timer)

	h.assert_sent(message.type.task_failed, REQUESTER, "failed - dispatch timeout")
end)

-- ============================================================
-- Scenario 4: Follower fails -> try next peer
-- ============================================================

h.suite("leader: follower failover")

h.test("granted follower sends exec_failed -> next peer gets grant", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id

	-- Both report capable
	h.send_task_capable(FOLLOWER_A, task_id)
	h.send_task_capable(FOLLOWER_B, task_id)

	-- A was granted (first capable)
	h.assert_sent(message.type.task_granted, FOLLOWER_A, "A granted first")

	-- A fails
	mock_uv.clear_sent_frames()
	h.send_task_exec_failed(FOLLOWER_A, task_id)

	-- B should now be granted
	h.assert_sent(message.type.task_granted, FOLLOWER_B, "B granted after A failed")
end)

h.test("all capable peers fail -> task_failed to requester", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id

	h.send_task_capable(FOLLOWER_A, task_id)
	h.send_task_capable(FOLLOWER_B, task_id)

	-- A granted and fails
	h.send_task_exec_failed(FOLLOWER_A, task_id)
	-- B granted and fails
	h.send_task_exec_failed(FOLLOWER_B, task_id)

	h.assert_sent(message.type.task_failed, REQUESTER, "failed - all peers failed")
end)

h.test("execution timeout on granted peer -> next peer tried", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id
	h.send_task_capable(FOLLOWER_A, task_id)
	h.send_task_capable(FOLLOWER_B, task_id)

	-- A is granted. Get the execution timeout timer
	local task = G.role.tasks[task_id]
	h.assert_not_nil(task, "task must exist")
	h.assert_not_nil(task.timeout_timer, "execution timeout must be set")

	-- Fire execution timeout
	mock_uv.clear_sent_frames()
	mock_uv.fire_timer(task.timeout_timer)

	-- B should get the grant
	h.assert_sent(message.type.task_granted, FOLLOWER_B, "B granted after A timeout")
end)

h.test("three followers: A fails, B fails, C succeeds", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)
	h.add_peer(FOLLOWER_C)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id

	-- All report capable
	h.send_task_capable(FOLLOWER_A, task_id)
	h.send_task_capable(FOLLOWER_B, task_id)
	h.send_task_capable(FOLLOWER_C, task_id)

	-- A is granted and fails
	h.send_task_exec_failed(FOLLOWER_A, task_id)
	-- B is granted and fails
	h.send_task_exec_failed(FOLLOWER_B, task_id)
	-- C is granted and succeeds
	h.send_task_exec_done(FOLLOWER_C, task_id)

	h.assert_sent(message.type.task_completed, REQUESTER, "completed by C")
end)

-- ============================================================
-- Scenario 5: Edge cases
-- ============================================================

h.suite("leader: edge cases")

h.test("task_capable for unknown task -> sends denied", function()
	h.setup_leader()

	h.send_task_capable(FOLLOWER_A, 99999)

	h.assert_sent(message.type.task_denied, FOLLOWER_A, "denied unknown task")
end)

h.test("task_not_capable for unknown task -> ignored (no crash)", function()
	h.setup_leader()
	-- Should not error
	h.send_task_not_capable(FOLLOWER_A, 99999)
end)

h.test("exec_done from wrong peer -> ignored", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)
	local task_id = G.last_command_id

	h.send_task_capable(FOLLOWER_A, task_id)
	-- A is granted

	mock_uv.clear_sent_frames()
	-- B (wrong peer) sends exec_done
	h.send_task_exec_done(FOLLOWER_B, task_id)

	-- Should NOT send completed to requester
	h.assert_not_sent(message.type.task_completed, REQUESTER, "should ignore wrong peer exec_done")
end)

h.test("exec_failed from wrong peer -> ignored", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)
	local task_id = G.last_command_id

	h.send_task_capable(FOLLOWER_A, task_id)
	-- A is granted

	mock_uv.clear_sent_frames()
	-- B (wrong peer) sends exec_failed
	h.send_task_exec_failed(FOLLOWER_B, task_id)

	-- A should still be granted, no failover triggered
	h.assert_not_sent(message.type.task_granted, FOLLOWER_B, "should not re-grant")
	local task = G.role.tasks[task_id]
	h.assert_not_nil(task, "task should still exist")
	h.assert_eq(task.granted_peer, FOLLOWER_A, "A should still be granted peer")
end)

h.test("exec_done for unknown task -> ignored (no crash)", function()
	h.setup_leader()
	h.send_task_exec_done(FOLLOWER_A, 99999)
end)

h.test("exec_failed for unknown task -> ignored (no crash)", function()
	h.setup_leader()
	h.send_task_exec_failed(FOLLOWER_A, 99999)
end)

h.test("task ID increments correctly", function()
	h.setup_leader()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	h.send_task_request(REQUESTER, 0)
	h.assert_eq(G.last_command_id, 1, "first task id")

	h.send_task_request(REQUESTER, 0)
	h.assert_eq(G.last_command_id, 2, "second task id")

	h.send_task_request(REQUESTER, 0)
	h.assert_eq(G.last_command_id, 3, "third task id")
end)

h.test("task ID wraps on u32 overflow", function()
	h.setup_leader()
	mock_tasks.set_capable(true)
	mock_tasks.set_execute_result(true)

	G.last_command_id = 0xFFFFFFFF
	h.send_task_request(REQUESTER, 0)
	h.assert_eq(G.last_command_id, 1, "should wrap to 1")
end)

h.test("ping from follower -> sends pong + resets peer timer", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)

	mock_uv.clear_sent_frames()
	h.send_ping(FOLLOWER_A)

	h.assert_sent(message.type.pong, FOLLOWER_A, "pong response")
	-- Peer should still exist
	h.assert_not_nil(G.role.peers[FOLLOWER_A], "peer should still exist")
end)

h.test("denied sent to non-granted capable peers on task completion", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)
	h.add_peer(FOLLOWER_C)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)

	local task_id = G.last_command_id

	-- All report capable
	h.send_task_capable(FOLLOWER_A, task_id)
	h.send_task_capable(FOLLOWER_B, task_id)
	h.send_task_capable(FOLLOWER_C, task_id)

	-- A is granted and succeeds
	mock_uv.clear_sent_frames()
	h.send_task_exec_done(FOLLOWER_A, task_id)

	-- B and C should receive denied
	h.assert_sent(message.type.task_denied, FOLLOWER_B, "B denied")
	h.assert_sent(message.type.task_denied, FOLLOWER_C, "C denied")
	-- A should NOT receive denied (it completed the task)
	h.assert_not_sent(message.type.task_denied, FOLLOWER_A, "A not denied")
end)

h.test("task_capable after task already granted -> peer added to list but no new grant", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)
	h.add_peer(FOLLOWER_B)

	mock_tasks.set_capable(false)
	h.send_task_request(REQUESTER, 0)
	local task_id = G.last_command_id

	-- A reports capable -> gets granted
	h.send_task_capable(FOLLOWER_A, task_id)
	h.assert_sent(message.type.task_granted, FOLLOWER_A, "A granted")

	-- B reports capable while A is executing
	mock_uv.clear_sent_frames()
	h.send_task_capable(FOLLOWER_B, task_id)

	-- B should NOT get granted yet (A is still executing)
	h.assert_not_sent(message.type.task_granted, FOLLOWER_B, "B should not be granted yet")

	-- B should be in the capable_peers list though (for failover)
	local task = G.role.tasks[task_id]
	h.assert_not_nil(task)
	local found_b = false
	for _, port in ipairs(task.capable_peers) do
		if port == FOLLOWER_B then
			found_b = true
		end
	end
	h.assert_true(found_b, "B should be in capable_peers")
end)

h.test("multiple concurrent tasks work independently", function()
	h.setup_leader()
	h.add_peer(FOLLOWER_A)

	mock_tasks.set_capable(false)

	-- Send two task requests from different ports
	h.send_task_request(REQUESTER, 0)
	local task_id_1 = G.last_command_id

	local REQUESTER_2 = 50002
	h.send_task_request(REQUESTER_2, 0)
	local task_id_2 = G.last_command_id

	h.assert_ne(task_id_1, task_id_2, "different task ids")

	-- Both tasks should exist
	h.assert_not_nil(G.role.tasks[task_id_1], "task 1 exists")
	h.assert_not_nil(G.role.tasks[task_id_2], "task 2 exists")

	-- Complete task 1
	h.send_task_capable(FOLLOWER_A, task_id_1)
	h.send_task_exec_done(FOLLOWER_A, task_id_1)

	-- Task 1 should be cleaned up, task 2 still exists
	h.assert_nil(G.role.tasks[task_id_1], "task 1 cleaned up")
	h.assert_not_nil(G.role.tasks[task_id_2], "task 2 still exists")
end)

return h.run()
