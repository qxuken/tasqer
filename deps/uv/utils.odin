package uv

import "base:runtime"
import "core:c"
import "core:mem"

uv_context: runtime.Context

odin_malloc :: proc "c" (size: c.size_t) -> rawptr {
	context = uv_context
	data, err := mem.alloc(cast(int)size)
	return data if err == .None else nil
}

odin_realloc :: proc "c" (ptr: rawptr, new_size: c.size_t) -> rawptr {
	if ptr == nil do return odin_malloc(new_size)
	context = uv_context
	info := mem.query_info(ptr, context.allocator)
	old_size, ok := info.size.(int)
	if !ok do return nil
	data, err := mem.resize(ptr, old_size, cast(int)new_size)
	return data if err == .None else nil
}

odin_calloc :: proc "c" (count: c.size_t, size: c.size_t) -> rawptr {
	return odin_malloc(count * size)
}

odin_free :: proc "c" (ptr: rawptr) {
	context = uv_context
	mem.free(ptr)
}

setup :: proc() {
	uv_context = context
	replace_allocator(odin_malloc, odin_realloc, odin_calloc, odin_free)
	setup_args(cast(c.int)len(runtime.args__), raw_data(runtime.args__))
}
