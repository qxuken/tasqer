package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "deps/luajit"
import "deps/luv"
import "deps/uv"
_ :: mem

entry :: "main.lua"

get_lua_resolution_path :: proc() -> cstring {
	dir := filepath.dir(os.args[0])
	defer delete(dir)
	res_src := transmute([]u8)filepath.join({dir, "?.lua0"})
	res_src[len(res_src) - 1] = 0
	return cast(cstring)(raw_data(res_src))
}

lua_run :: proc(src: cstring) {
	_context := context
	state := luajit.open(luajit.odin_allocator, &_context)
	ensure(state != nil)
	defer luajit.close(state)

	luajit.setup_args(state)
	luajit.L_openlibs(state)
	luajit.preload_library(state, "luv", luv.luaopen_luv)
	resolution_path := get_lua_resolution_path()
	defer delete(resolution_path)
	luajit.set_resolution_path(state, resolution_path)

	luajit.getglobal(state, "require")
	luajit.pushstring(state, "main")
	if (luajit.pcall(state, 1, 1, 0) != 0) {
		fmt.println(luajit.tostring(state, -1))
		luajit.pop(state, 1)
		os.exit(1)
	}
}

when ODIN_DEBUG {
	track: mem.Tracking_Allocator
	report_allocations :: proc() {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %m\n", leak.location, leak.size)
		}
	}
}

main :: proc() {
	when ODIN_DEBUG {
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)
		defer report_allocations()
	}
	uv.setup()
	lua_run(entry)
}
