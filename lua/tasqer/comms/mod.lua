--- Communication layer for leader-follower coordination.
--- Handles role election, task routing, and peer management.
--- @class CommsModule

local G = require("tasqer.G")
local logger = require("tasqer.logger")
local constants = require("tasqer.comms.constants")
local leader = require("tasqer.comms.leader")
local follower = require("tasqer.comms.follower")
local issuer = require("tasqer.comms.issuer")

--- @class CommsModule
local M = {}

M.role = constants.role
M.task_state = constants.task_state

--- Role for transition period
--- @return TransitionRole
local function new_transition_role()
	return {
		id = constants.role.transition,
	}
end

--- Default candidate role state
--- @return CandidateRole
local function new_candidate_role()
	return {
		id = constants.role.candidate,
	}
end

G.role = new_candidate_role()
G.last_command_id = 0

--- Clean up current role state and close socket connections.
--- Resets to candidate role after cleanup.
--- @return boolean
local function cleanup_role_and_shutdown_socket()
	if not G.role then
		G.role = new_candidate_role()
		return true
	end
	local role = G.role
	if G.role.id == constants.role.transition then
		return false
	end

	G.role = new_transition_role()
	if role.id == constants.role.candidate then
		return true
	end

	role.socket:recv_stop()
	if role.id == constants.role.leader then
		---@diagnostic disable-next-line: param-type-mismatch
		leader.cleanup_role(role)
	elseif role.id == constants.role.follower then
		---@diagnostic disable-next-line: param-type-mismatch
		follower.cleanup_role(role)
	elseif role.id == constants.role.issuer then
		---@diagnostic disable-next-line: param-type-mismatch
		issuer.cleanup_role(role)
	end
	role.socket:close()
	G.role = new_candidate_role()
	return true
end

--- Initialize communication - attempts to become leader, falls back to follower
--- @param retries integer? Number of retry attempts remaining (default: 3)
--- @return boolean success True if successfully initialized
--- @return string? error Error message if all retries exhausted
function M.run_comms(retries)
	local retries_left = retries and retries - 1 or 3
	if logger.is_debug() then
		logger.debug("run_comms: " .. retries_left)
	end
	if retries_left == 0 then
		return false, "No more retries, quiting"
	end
	if not cleanup_role_and_shutdown_socket() then
		return false, "Already running"
	end
	local err
	err = leader.try_init(M.run_comms)
	if err ~= nil then
		if logger.is_trace() then
			logger.trace(err)
		end
		err = follower.try_init(M.run_comms)
		if err ~= nil then
			if logger.is_trace() then
				logger.trace(err)
			end
			return M.run_comms(retries_left)
		end
	end
	return true, nil
end

--- Initialize communication - attempts to run tasks through cluster, falls back to execution
--- @param task IssuerTaskEntry The task
--- @param retries integer? Number of retry attempts remaining (default: 3)
--- @return string? error Error message if all retries exhausted
function M.run_task(task, retries)
	local retries_left = retries and retries - 1 or 3
	if logger.is_debug() then
		logger.debug("run_task: " .. retries_left)
	end
	if retries_left == 0 then
		return issuer.try_execute_task(task)
	end
	if not cleanup_role_and_shutdown_socket() then
		return "Already running"
	end
	local err
	err = leader.try_init(M.run_comms)
	if not err then
		logger.debug("no leader bound to the port")
		M.shutdown()
		return issuer.try_execute_task(task)
	end
	err = issuer.try_init(task, M.shutdown, function()
		return M.run_task(task, retries_left)
	end)
	if err ~= nil then
		if logger.is_trace() then
			logger.trace(err)
		end
		return M.run_task(task, retries_left)
	end
end

--- Shutdown communication
function M.shutdown()
	cleanup_role_and_shutdown_socket()
end

return M
