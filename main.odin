package main

import "core:fmt"
import "core:os"
import "deps/luajit"
import "deps/luv"

preload :: proc(state: ^luajit.State, name: cstring, open_proc: luajit.CFunction) {
	luajit.getglobal(state, "package")
	luajit.getfield(state, -1, "preload")
	luajit.pushcfunction(state, open_proc)
	luajit.setfield(state, -2, name)
	luajit.pop(state, 2)
}

main :: proc() {
	state := luajit.L_newstate()
	assert(state != nil)
	defer luajit.close(state)

	luajit.L_openlibs(state)
	preload(state, "luv", luv.luaopen_luv)

	if (luajit.L_dofile(state, "main.lua") != 0) {
		fmt.println(luajit.tostring(state, -1))
		luajit.pop(state, 1)
		os.exit(1)
	}
}
