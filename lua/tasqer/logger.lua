--- Logging utility module with configurable log levels and output.
--- @class LoggerModule

local G = require("tasqer.G")

--- @class LoggerModule
local M = {}

--- Log level constants
--- @enum LogLevel
M.level = {
	TRACE = 0,
	DEBUG = 1,
	INFO = 2,
	WARN = 3,
	ERROR = 4,
}

--- Default print function - outputs to stdout with level prefix
--- @param level LogLevel The log level
--- @param message string The message to print
function G.print(level, message)
	if level < G.log_level then
		return
	end
	if level == M.level.TRACE then
		print("TRACE: " .. message)
	elseif level == M.level.DEBUG then
		print("DEBUG: " .. message)
	elseif level == M.level.INFO then
		print("INFO: " .. message)
	elseif level == M.level.WARN then
		print("WARN: " .. message)
	elseif level == M.level.ERROR then
		print("ERROR: " .. message)
	end
end

--- Set a custom printer function for log output
--- @param p PrinterFunction The printer function to use
function M.set_printer(p)
	G.print = p
end

--- Check if TRACE level is enabled
--- @return boolean
function M.is_trace()
	return G.log_level <= M.level.TRACE
end

--- Check if DEBUG level is enabled
--- @return boolean
function M.is_debug()
	return G.log_level <= M.level.DEBUG
end

--- Log a message at TRACE level
--- @param message string The message to log
function M.trace(message)
	G.print(M.level.TRACE, message)
end

--- Log a message at DEBUG level
--- @param message string The message to log
function M.debug(message)
	G.print(M.level.DEBUG, message)
end

--- Log a message at INFO level
--- @param message string The message to log
function M.info(message)
	G.print(M.level.INFO, message)
end

--- Log a message at WARN level
--- @param message string The message to log
function M.warn(message)
	G.print(M.level.WARN, message)
end

--- Log a message at ERROR level
--- @param message string The message to log
function M.error(message)
	G.print(M.level.ERROR, message)
end

--- Dump a table recursively at specified log level
--- @param level LogLevel The log level to use
--- @param tbl table? The table to dump
--- @param indent string? Current indentation (internal use)
--- @param seen table<table, boolean>? Tables already seen (internal use, for cycle detection)
function M.dump(level, tbl, indent, seen)
	if not tbl or level > G.log_level then
		return
	end
	indent, seen = indent or "", seen or {}
	if seen[tbl] then
		G.print(level, indent .. "*RECURSION*")
		return
	end
	seen[tbl] = true
	for k, v in pairs(tbl) do
		if type(v) == "table" then
			G.print(level, ("%s[%s] = {"):format(indent, tostring(k)))
			M.dump(level, v, indent .. "  ", seen)
			G.print(level, indent .. "}")
		else
			G.print(level, ("%s[%s] = %s"):format(indent, tostring(k), tostring(v)))
		end
	end
end
--- Dump a table at DEBUG level
--- @param tbl table? The table to dump
--- @param indent string? Current indentation
--- @param seen table<table, boolean>? Tables already seen
function M.debug_dump(tbl, indent, seen)
	return M.dump(M.level.DEBUG, tbl, indent, seen)
end

--- Dump a table at TRACE level
--- @param tbl table? The table to dump
--- @param indent string? Current indentation
--- @param seen table<table, boolean>? Tables already seen
function M.trace_dump(tbl, indent, seen)
	return M.dump(M.level.TRACE, tbl, indent, seen)
end

return M
