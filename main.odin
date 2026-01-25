package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "deps/luajit"
import "deps/luv"
import "deps/uv"

lua_run :: proc(src: cstring = "main.lua") {
	_context := context
	state := luajit.newstate(luajit.odin_allocator, &_context)
	ensure(state != nil)
	defer luajit.close(state)

	luajit.L_openlibs(state)
	luajit.preload_library(state, "luv", luv.luaopen_luv)

	if (luajit.L_dofile(state, cstring(src)) != 0) {
		fmt.println(luajit.tostring(state, -1))
		luajit.pop(state, 1)
		os.exit(1)
	}
}

when ODIN_DEBUG {
	track: mem.Tracking_Allocator
	report_allocations :: proc() {
		fmt.println("exit")
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
	lua_run()
}
