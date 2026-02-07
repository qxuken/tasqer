--- Task registry module for managing a task type modules.
--- Provides registration, lookup, and encoding/decoding of tasks.
--- @class TasksModule

local G = require("tasqer.G")

--- @class TasksModule
local M = {}

--- Validate that a task module has all required fields and methods
--- @param task TaskModule The task module to validate
local function ensure_task_module(task)
	assert(type(task) == "table", "task module must be a table")
	assert(type(task.id) == "number", "task module must define numeric id")
	assert(type(task.encode) == "function", "task module must expose encode")
	assert(type(task.decode) == "function", "task module must expose decode")
	assert(type(task.can_execute) == "function", "task module must expose can_execute")
	assert(type(task.execute) == "function", "task module must expose execute")
end

--- Register a task module in the global registry
--- @param task TaskModule The task module to register
function M.register(task)
	ensure_task_module(task)
	if G.command_registry[task.id] then
		error("task id already registered: " .. task.id)
	end
	G.command_registry[task.id] = task
end

--- Get a registered task module by its type ID
--- @param task_id integer The task type identifier
--- @return TaskModule? task The task module, or nil if not found
function M.get(task_id)
	return G.command_registry[task_id]
end

--- Decode task data using the registered task module
--- @param type_id number The task type identifier
--- @param data string The encoded task data
--- @return table|nil payload The decoded payload, or nil on error
--- @return string|nil err Error message if decoding failed
function M.decode_task(type_id, data)
	local task = M.get(type_id)
	if not task then
		return nil, "unknown task type: " .. type_id
	end
	return task.decode(data)
end

--- Encode task payload using the registered task module
--- @param type_id number The task type identifier
--- @param payload table The payload to encode
--- @return string|nil data The encoded data, or nil on error
--- @return string|nil err Error message if encoding failed
function M.encode_task(type_id, payload)
	local task = M.get(type_id)
	if not task then
		return nil, "unknown task type: " .. type_id
	end
	return task.encode(payload)
end

--- Try to execute the task using the registered task module
--- @param type_id number The task type identifier
--- @param payload table The task payload
--- @param callback fun(res: boolean) The callback on completion
--- @return string|nil err Error message if decoding failed
function M.try_execute(type_id, payload, callback)
	local task = M.get(type_id)
	if not task then
		callback(false)
		return "unknown task type: " .. type_id
	end
	return task.can_execute(payload, function(capable)
		if capable then
			task.execute(payload, callback)
		else
			callback(false)
		end
	end)
end

return M
