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
