const posix_deps = [-lm]
const linux_libs = [./lib/ubuntu/libluajit.a ./lib/ubuntu/libluv.a ./lib/ubuntu/libuv.a]
const darwin_libs = [./lib/darwin/libluajit.a ./lib/darwin/libluv.a ./lib/darwin/libuv.a]

const windows_libs = [.\lib\windows\libluajit.lib .\lib\windows\luv.lib .\lib\windows\libuv.lib]
const windows_deps = [-lws2_32 -liphlpapi -ladvapi32 -luser32 -lshell32 -lole32 -ldbghelp -luserenv]

const generic_libs = [-lluajit -lluv -luv]

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

def compile [out, libs, deps] {
	mkdir $out_dir
	let c = compiler
	let args = [./main.c '-o' $out ...$libs ...$deps]
	print ([$c] | append $args | str join " ")
	run-external $c ...$args
}

export def main [] {
	let info = uname
	let kernel = $info.kernel-name | str downcase
	let arch = $info.machine | str downcase
	if $kernel =~ "windows" and $arch == "x86_64" {
		compile $windows_out $windows_libs $windows_deps
	} else if $kernel =~ "linux" and $arch == "x86_64" {
		compile $posix_out $linux_libs $posix_deps
	} else if $kernel =~ "darwin" and $arch == "arm64" {
		compile $posix_out $darwin_libs $posix_deps
	} else {
		compile $windows_out $generic_libs $posix_deps
	}
}
