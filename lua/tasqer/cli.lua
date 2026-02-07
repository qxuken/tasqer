local openfile = require("tasqer.tasks.openfile")

local M = {}

local SERVE_ID = 0

--- Task type name to module ID mapping
--- @type table<string, integer>
M.task_types = {
	serve = SERVE_ID,
	openfile = openfile.id,
}

--- Print usage information to stdout
local function print_usage()
	print("Usage:")
	print("")
	print("Task types:")
	print("  serve                        - Start a local server")
	print("  openfile <path> [row] [col]  - Open file at location")
	print("")
	print("Examples:")
	print("  edit_open openfile /path/to/file.lua")
	print("  edit_open openfile /path/to/file.lua 10 5")
end

--- Parse command-line arguments for the openfile task
--- @param args string[] The argument list (path, row, col)
--- @return OpenFilePayload? payload The parsed payload, or nil on error
--- @return string? err Error message if parsing failed
local function parse_openfile_args(args)
	local path = args[1]
	if not path then
		return nil, "openfile requires a path argument"
	end
	local row = tonumber(args[2]) or 1
	local col = tonumber(args[3]) or 1
	return {
		path = path,
		row = row,
		col = col,
	}, nil
end

--- Parse command-line arguments for a task type
--- @return integer type_id The parsed type_id
--- @return table? payload The parsed payload
function M.parse_args()
	if not arg or #arg < 2 then
		print_usage()
		os.exit(1)
	end

	local task_name = arg[2]
	local type_id = M.task_types[task_name]
	if type_id == nil then
		print("Error: unknown task type: " .. task_name)
		print_usage()
		os.exit(1)
	end

	local args = {}
	for i = 3, #arg do
		table.insert(args, arg[i])
	end

	local payload, err
	if type_id == openfile.id then
		payload, err = parse_openfile_args(args)
	end
	if err ~= nil then
		print("Error: " .. err)
		print_usage()
		os.exit(1)
	end
	return type_id, payload
end

return M
