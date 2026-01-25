package luv

import "../luajit"
import "core:c"

_ :: c
_ :: luajit

when ODIN_OS == .Windows {
	foreign import lib "windows/luv.lib"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib "linux/libluv.a"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib "darwin/libluv.a"
} else {
	foreign import lib "system:luv"
}

@(default_calling_convention = "c")
foreign lib {
	luaopen_luv :: proc(state: ^luajit.State) -> c.int ---
}
