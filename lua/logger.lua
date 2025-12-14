local G = require("lua.G")

local M = {}

M.level = {
	TRACE = 0,
	DEBUG = 1,
	INFO = 2,
	WARN = 3,
}

function M.print(level, message)
	if level < G.log_level then
		return
	end
	if level == M.level.trace then
		print("TRACE: " .. message)
	elseif level == M.level.DEBUG then
		print("DEBUG: " .. message)
	elseif level == M.level.INFO then
		print("INFO: " .. message)
	elseif level == M.level.WARN then
		print("WARN: " .. message)
	end
end

function M.set_printer(p)
	M.print = p
end
function M.trace(message)
	M.print(M.level.TRACE, message)
end
function M.debug(message)
	M.print(M.level.DEBUG, message)
end
function M.info(message)
	M.print(M.level.INFO, message)
end
function M.warn(message)
	M.print(M.level.WARN, message)
end

function M.dump(level, tbl, indent, seen)
	if not tbl or level > G.log_level then
		return
	end
	indent, seen = indent or "", seen or {}
	if seen[tbl] then
		M.print(level, indent .. "*RECURSION*")
		return
	end
	seen[tbl] = true
	for k, v in pairs(tbl) do
		if type(v) == "table" then
			M.print(level, ("%s[%s] = {"):format(indent, tostring(k)))
			M.dump(level, v, indent .. "  ", seen)
			M.print(level, indent .. "}")
		else
			M.print(level, ("%s[%s] = %s"):format(indent, tostring(k), tostring(v)))
		end
	end
end
function M.debug_dump(tbl, indent, seen)
	return M.dump(M.level.DEBUG, tbl, indent, seen)
end
function M.trace_dump(tbl, indent, seen)
	return M.dump(M.level.TRACE, tbl, indent, seen)
end

return M
