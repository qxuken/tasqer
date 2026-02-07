--- Test runner that executes all test files and reports aggregate results.
--- Usage: lua tests/run_all.lua
---   (run from the project root directory)

-- Add lua/ to package path so require("tasqer.xxx") resolves to lua/tasqer/xxx.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

io.write("=" .. string.rep("=", 59) .. "\n")
io.write("  Running test suite\n")
io.write("=" .. string.rep("=", 59) .. "\n\n")

local total_failures = 0

local test_files = {
	{ name = "test_messages", module = "tests.test_messages" },
	{ name = "test_leader", module = "tests.test_leader" },
	{ name = "test_follower", module = "tests.test_follower" },
	{ name = "test_issuer", module = "tests.test_issuer" },
}

for _, tf in ipairs(test_files) do
	io.write("-" .. string.rep("-", 59) .. "\n")
	io.write("  " .. tf.name .. "\n")
	io.write("-" .. string.rep("-", 59) .. "\n")

	-- Clear module cache so each test file gets fresh state
	-- (except for core modules that maintain state correctly)
	local ok, result = pcall(require, tf.module)
	if ok then
		total_failures = total_failures + (result or 0)
	else
		total_failures = total_failures + 1
		io.write("  ERROR loading " .. tf.name .. ": " .. tostring(result) .. "\n")
	end

	-- Remove the test module from cache so it can be re-run
	package.loaded[tf.module] = nil
	io.write("\n")
end

io.write("=" .. string.rep("=", 59) .. "\n")
if total_failures == 0 then
	io.write("  ALL TESTS PASSED (" .. os.date("%H:%M:%S") .. ")\n")
else
	io.write("  " .. total_failures .. " FAILURE(S) (" .. os.date("%H:%M:%S") .. ")\n")
end
io.write("=" .. string.rep("=", 59) .. "\n")

os.exit(total_failures == 0 and 0 or 1)
