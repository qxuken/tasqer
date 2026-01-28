--- Communication layer for leader-follower coordination.
--- Handles role election, task routing, and peer management.
--- @class CommsModule

local G = require("lua.G")
local logger = require("lua.logger")
local constants = require("lua.comms.constants")
local leader = require("lua.comms.leader")
local follower = require("lua.comms.follower")

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
function M.cleanup_role_and_shutdown_socket()
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
	logger.debug("run_comms: " .. retries_left)
	if retries_left == 0 then
		return false, "No more retries, quiting"
	end
	if not M.cleanup_role_and_shutdown_socket() then
		return false, "Already running"
	end
	local err
	err = leader.try_init(M.run_comms)
	if err ~= nil then
		logger.trace(err)
		err = follower.try_init(M.run_comms)
		if err ~= nil then
			logger.trace(err)
			return M.run_comms(retries_left)
		end
	end
	return true, nil
end

return M
