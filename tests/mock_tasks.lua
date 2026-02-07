--- Mock task module for testing.
--- Provides a controllable task that can be registered in the task registry.
--- Allows tests to set can_execute and execute results per-call.

local G = require("tasqer.G")
local tasks = require("tasqer.tasks.mod")

local M = {}

--- Internal state
local _state = {}

function M.reset()
	_state = {
		can_execute_result = false, -- default: not capable
		execute_result = true, -- default: succeed
		can_execute_calls = {},
		execute_calls = {},
		can_execute_fn = nil, -- optional custom function override
		execute_fn = nil, -- optional custom function override
	}
end

M.reset()

--- The mock task type ID
M.TASK_TYPE_ID = 1

--- Create a fresh mock task module and register it
function M.register()
	-- Clear existing registry entry
	G.command_registry = {}

	local task_module = {
		id = M.TASK_TYPE_ID,
		encode = function(payload)
			-- Simple encode: just the path as u16-prefixed string + row u32 + col u32
			local encode_mod = require("tasqer.message.encode")
			local path_data = encode_mod.pack_str_u16(payload.path or "test.txt")
			local row_data = encode_mod.u32(payload.row or 1)
			local col_data = encode_mod.u32(payload.col or 1)
			return table.concat({ path_data, row_data, col_data }), nil
		end,
		decode = function(data)
			local encode_mod = require("tasqer.message.encode")
			local path, row, col, off, err
			off = 1
			path, off, err = encode_mod.unpack_str_u16(data, off)
			if not path then
				return nil, err
			end
			row, off, err = encode_mod.unpack_u32(data, off)
			if not row then
				return nil, err
			end
			col, off, err = encode_mod.unpack_u32(data, off)
			if not col then
				return nil, err
			end
			return { path = path, row = row, col = col }, nil
		end,
		can_execute = function(payload, callback)
			table.insert(_state.can_execute_calls, payload)
			if _state.can_execute_fn then
				return _state.can_execute_fn(payload, callback)
			end
			callback(_state.can_execute_result)
		end,
		execute = function(payload, callback)
			table.insert(_state.execute_calls, payload)
			if _state.execute_fn then
				return _state.execute_fn(payload, callback)
			end
			callback(_state.execute_result)
		end,
	}

	tasks.register(task_module)
	return task_module
end

--- Set can_execute to return true or false
function M.set_capable(capable)
	_state.can_execute_result = capable
end

--- Set execute to return true or false
function M.set_execute_result(result)
	_state.execute_result = result
end

--- Set a custom can_execute function (for deferred callbacks etc)
--- @param fn fun(payload: table, callback: fun(capable: boolean))
function M.set_can_execute_fn(fn)
	_state.can_execute_fn = fn
end

--- Set a custom execute function
--- @param fn fun(payload: table, callback: fun(result: boolean))
function M.set_execute_fn(fn)
	_state.execute_fn = fn
end

--- Get the number of can_execute calls
function M.can_execute_call_count()
	return #_state.can_execute_calls
end

--- Get the number of execute calls
function M.execute_call_count()
	return #_state.execute_calls
end

--- Get can_execute call payloads
function M.get_can_execute_calls()
	return _state.can_execute_calls
end

--- Get execute call payloads
function M.get_execute_calls()
	return _state.execute_calls
end

--- Create a standard test payload
function M.make_payload(path, row, col)
	return {
		path = path or "test.txt",
		row = row or 1,
		col = col or 1,
	}
end

--- Encode a payload to raw data (for building task_request / task_dispatch frames)
function M.encode_payload(payload)
	local encode_mod = require("tasqer.message.encode")
	payload = payload or M.make_payload()
	local path_data = encode_mod.pack_str_u16(payload.path)
	local row_data = encode_mod.u32(payload.row)
	local col_data = encode_mod.u32(payload.col)
	return table.concat({ path_data, row_data, col_data })
end

return M
