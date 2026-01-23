const windows_libs = [./lib/libluajit.lib ./lib/luv.lib ./lib/libuv.lib ./lib/luajit.lib]
const windows_uv_deps = [-lws2_32 -liphlpapi -ladvapi32 -luser32 -lshell32 -lole32 -ldbghelp -luserenv]

const out_dir = (path self . | path join build)
const windows_out = $out_dir | path join "main.exe"

export def windows [] {
	mkdir $out_dir
	run-external clang ./main.c '-o' $windows_out ...$windows_libs ...$windows_uv_deps
}

export def main [] {
	match (sys host | get name) {
		"Windows" => windows
	}
}
