package luv

import "core:c"
import "../luajit"
_ :: c
_ :: luajit

when ODIN_OS == .Windows {
	foreign import lib {
		"system:Advapi32.lib",
		"system:Crypt32.lib",
		"system:Normaliz.lib",
		"system:Secur32.lib",
		"system:Wldap32.lib",
		"system:Ws2_32.lib",
		"system:iphlpapi.lib",
		"system:userenv.lib",
		"system:Dbghelp.lib",
		"system:ole32.lib",
		"system:Shell32.lib",
		"system:user32.lib",
		"windows/libuv.lib",
		"windows/luv.lib",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib {"linux/libuv.a", "linux/luv.a"}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib {"darwin/libuv.a", "darwin/luv.a"}
} else {
	foreign import lib {"system:uv", "system:luv"}
}

@(default_calling_convention="c")
foreign lib {
	luaopen_luv :: proc(state: ^luajit.State) -> c.int ---
}
