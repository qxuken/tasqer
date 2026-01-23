const ubuntu_libs = [./lib/ubuntu/libluajit.a ./lib/ubuntu/libluv.a ./lib/ubuntu/libuv.a]
const posix_deps = [-lm]
const windows_libs = [./lib/windows/luv.lib ./lib/windows/libuv.lib ./lib/windows/luajit.lib]
const windows_uv_deps = [-lws2_32 -liphlpapi -ladvapi32 -luser32 -lshell32 -lole32 -ldbghelp -luserenv]

const out_dir = (path self . | path join build)
const windows_out = $out_dir | path join "main.exe"
const posix_out = $out_dir | path join "main"

def compiler [] {
	let cenv = $env | get -o CC | default "clang"
	if $cenv =~ "clang" {
		$cenv
	} else {
		"clang"
	}
}

export def windows [] {
	mkdir $out_dir
	run-external (compiler) ./main.c '-o' $windows_out ...$windows_libs ...$windows_uv_deps
}

export def posix [libs] {
	mkdir $out_dir
	run-external (compiler) ./main.c '-o' $posix_out ...$libs ...$posix_deps
}


export def main [] {
	match (sys host | get name) {
		"Windows" => windows
		"Ubuntu" => (posix $ubuntu_libs)
	}
}
