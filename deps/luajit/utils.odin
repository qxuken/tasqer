package luajit

import "base:runtime"
import "core:c"
import "core:mem"

odin_allocator :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> (buf: rawptr) {
	old_size := cast(int)osize
	new_size := cast(int)nsize
	context = (^runtime.Context)(ud)^

	if ptr == nil {
		data, err := mem.alloc(new_size)
		return data if err == .None else nil
	} else {
		if nsize > 0 {
			data, err := mem.resize(ptr, old_size, new_size)
			return data if err == .None else nil
		} else {
			mem.free(ptr)
			return
		}
	}
}

preload_library :: proc(state: ^State, name: cstring, open_proc: CFunction) {
	getglobal(state, "package")
	getfield(state, -1, "preload")
	pushcfunction(state, open_proc)
	setfield(state, -2, name)
	pop(state, 2)
}

set_resolution_path :: proc(state: ^State, new_value: cstring, field: cstring = "path") {
	getglobal(state, "package")
	getfield(state, -1, field)
	old_value_len: c.size_t; old_value := tolstring(state, -1, &old_value_len)
	pop(state, 1)
	if old_value != nil && old_value_len > 0 {
		pushfstring(state, "%s;%s", new_value, old_value)
	} else {
		pushstring(state, new_value)
	}
	setfield(state, -2, field)
	pop(state, 1)
}


setup_args :: proc(state: ^State) {
	newtable(state)
	for arg, i in runtime.args__ {
		pushstring(state, arg)
		rawseti(state, -2, cast(c.int)i + 1)
	}
	setglobal(state, "arg")
}
