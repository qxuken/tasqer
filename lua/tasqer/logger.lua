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

local LOG_NAME_LENGTH = 5
local names = {}
for level, val in pairs(M.level) do
	local name = level
	if #name < LOG_NAME_LENGTH then
		name = (" "):rep(LOG_NAME_LENGTH - #name) .. name
	end
	names[val] = name
end

--- Default print function - outputs to stdout with level prefix
--- @param level LogLevel The log level
--- @param message string The message to print
function G.print(level, message)
	local level_name = names[level]
	if level < G.log_level or not level_name then
		return
	end
	local ts = os.time()
	return io.write(ts, " - ", level_name, ": ", message, "\n")
end

--- Level gate for the G.print
--- @param level LogLevel The log level
--- @param message string The message to print
function M.print(level, message)
	if level < G.log_level then
		return
	end
	return G.print(level, message)
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
	return M.print(M.level.TRACE, message)
end

--- Log a message at DEBUG level
--- @param message string The message to log
function M.debug(message)
	return M.print(M.level.DEBUG, message)
end

--- Log a message at INFO level
--- @param message string The message to log
function M.info(message)
	return M.print(M.level.INFO, message)
end

--- Log a message at WARN level
--- @param message string The message to log
function M.warn(message)
	return M.print(M.level.WARN, message)
end

--- Log a message at ERROR level
--- @param message string The message to log
function M.error(message)
	return M.print(M.level.ERROR, message)
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
