package uv

import "core:c"
_ :: c

when ODIN_OS == .Windows {
	foreign import lib {"system:Advapi32.lib", "system:Crypt32.lib", "system:Normaliz.lib", "system:Secur32.lib", "system:Wldap32.lib", "system:Ws2_32.lib", "system:iphlpapi.lib", "system:userenv.lib", "system:Dbghelp.lib", "system:ole32.lib", "system:Shell32.lib", "system:user32.lib", "windows/libuv.lib"}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib "linux/libuv.a"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib "darwin/libuv.a"
} else {
	foreign import lib "system:libuv"
}

@(link_prefix = "uv_")
@(default_calling_convention = "c")
foreign lib {
	setup_args :: proc(argc: c.int, argv: rawptr) -> ^^c.char ---
	replace_allocator :: proc(malloc: proc(size: c.size_t) -> rawptr, realloc: proc(ptr: rawptr, new_size: c.size_t) -> rawptr, calloc: proc(count: c.size_t, size: c.size_t) -> rawptr, free: proc(ptr: rawptr)) ---
}
