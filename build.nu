use std "path add"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const BUILD_SCRIPT_LOCATION = path self .

const PROGRAM_NAME = "tasqer"
const APP_NAME = $PROGRAM_NAME | str capitalize
const PROGRAM_VERSION = "1.0"
const PROGRAM_COMMAND = "openfile"

const FILE_TYPES = {
	".txt":  {mime: "text/plain",         UTType: "public.plain-text"},
	".lua":  {mime: "text/x-lua",         UTType: "public.source-code"},
	".py":   {mime: "text/x-python",      UTType: "public.python-script"},
	".js":   {mime: "text/javascript",    UTType: "com.netscape.javascript-source"},
	".ts":   {mime: "text/x-typescript",  UTType: "com.microsoft.typescript"},
	".c":    {mime: "text/x-csrc",        UTType: "public.c-source"},
	".h":    {mime: "text/x-chdr",        UTType: "public.c-header"},
	".cpp":  {mime: "text/x-c++src",      UTType: "public.c-plus-plus-source"},
	".hpp":  {mime: "text/x-c++hdr",      UTType: "public.c-plus-plus-header"},
	".rs":   {mime: "text/x-rust",        UTType: "public.source-code"},
	".go":   {mime: "text/x-go",          UTType: "public.source-code"},
	".java": {mime: "text/x-java",        UTType: "com.sun.java-source"},
	".rb":   {mime: "text/x-ruby",        UTType: "public.ruby-script"},
	".sh":   {mime: "text/x-shellscript", UTType: "public.shell-script"},
	".json": {mime: "application/json",   UTType: "public.json"},
	".yaml": {mime: "text/x-yaml",        UTType: "public.yaml"},
	".yml":  {mime: "text/x-yaml",        UTType: "public.yaml"},
	".toml": {mime: "text/x-toml",        UTType: "public.source-code"},
	".xml":  {mime: "text/xml",           UTType: "public.xml"},
	".html": {mime: "text/html",          UTType: "public.html"},
	".css":  {mime: "text/css",           UTType: "public.css"},
	".md":   {mime: "text/markdown",      UTType: "net.ia.markdown"},
	".odin": {mime: "text/plain",         UTType: "public.source-code"},
	".nu":   {mime: "text/plain",         UTType: "public.source-code"},
	".sum":  {mime: "text/plain",         UTType: "public.source-code"},
}

const ENV_MARKER = $"# ($PROGRAM_NAME)-editor"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get-extensions []: nothing -> list<string> { $FILE_TYPES | transpose key value | get key          }
def get-mime-types []: nothing -> list<string> { $FILE_TYPES | transpose key value | get value.mime   | uniq }
def get-uttypes    []: nothing -> list<string> { $FILE_TYPES | transpose key value | get value.UTType | uniq }

def get-os []: nothing -> string {
	uname | get kernel-name
}

def get-symlink-path []: nothing -> path {
	"~/.local/bin" | path expand | path join $PROGRAM_NAME
}

def get-default-install-path []: nothing -> path {
	if (get-os) == "Windows_NT" {
		if "LOCALAPPDATA" in $env {
			[$env.LOCALAPPDATA "Programs" $PROGRAM_NAME] | path join
		} else {
			["C" "Program Files" $PROGRAM_NAME] | path join
		}
	} else {
		"~/.local/share" | path expand | path join $PROGRAM_NAME
	}
}

def get-binary-name []: nothing -> string {
	if (get-os) == "Windows_NT" { $"($PROGRAM_NAME).exe" } else { $PROGRAM_NAME }
}

def update-profile [profile_path: path, --remove-only] {
	let editor_line = $'export EDITOR="($PROGRAM_NAME) ($PROGRAM_COMMAND)" ($ENV_MARKER)'
	let visual_line = $'export VISUAL="($PROGRAM_NAME) ($PROGRAM_COMMAND)" ($ENV_MARKER)'

	print $"Appending EDITOR/VISUAL to ($profile_path)"
	(if ($profile_path | path exists) {
		open $profile_path | lines | where ($it | str ends-with $ENV_MARKER) == false
	} else {
		[]
	})
	| append (if $remove_only {[]} else {[$editor_line $visual_line]})
	| str join (char newline)
	| save -f $profile_path
}

# --------------------------------------------------------------

export def test [--watch (-w)] {
	let cmd = { run-external lua "./tests/run_all.lua" }
	do $cmd
	if $watch {
		watch . --glob **/*.lua --debounce 50ms $cmd
	}
}
export alias "main test" = test

export def main [--debug (-d)] {
	mut args = ["build" "." "-vet" $"-out:(get-binary-name)"]
	if $debug {
		$args = $args | append row
	}
	print (["odin"] | append $args | str join " ")
	run-external odin ...$args
}

# ---------------------------------------------------------------------------
# Install: copy files
# ---------------------------------------------------------------------------

def install-copy-files [install_path: string] {
	let bin = get-binary-name
	let src_bin = $BUILD_SCRIPT_LOCATION | path join $bin
	let src_lua = $BUILD_SCRIPT_LOCATION | path join "lua"

	if not ($src_bin | path exists) {
		main
	}
	if not ($src_lua | path exists) {
		print "Error: lua directory not found."
		exit 1
	}

	print $"Creating install directory: ($install_path)"
	mkdir $install_path

	print $"Copying ($bin) -> ($install_path)"
	cp $src_bin $install_path

	let dest_lua = $install_path | path join "lua"
	if ($dest_lua | path exists) {
		rm -rf $dest_lua
	}
	print $"Copying ($src_lua) -> ($dest_lua)"
	cp -r $src_lua $install_path

	print "Files copied."
}

# ---------------------------------------------------------------------------
# Install: Windows
# ---------------------------------------------------------------------------

def install-windows [install_path: string] {
	let bin = get-binary-name
	let exe = $install_path | path join $bin

	if not ($env.PATH | any {|it| $it == $install_path}) {
		print $"Appending ($install_path) to path"
		$env.PATH = $env.PATH | append $install_path
		^reg add "HKCU\\Environment" /v PATH /t REG_EXPAND_SZ /d ($env.PATH | str join (char esep)) /f
	}

	# Register file type
	print $"Registering ($APP_NAME) in registry..."
	^reg add $'HKCU\Software\Classes\($APP_NAME)' /ve /t REG_SZ /d $APP_NAME /f
	# ^reg add $'HKCU\Software\Classes\($APP_NAME)\DefaultIcon' /ve /t REG_SZ /d $'"($exe)",0' /f

	# Register file type
	print $"Registering file type ($APP_NAME)..."
	let open_cmd = $'"($exe)" ($PROGRAM_COMMAND) "%1"'
	^reg add $'HKCU\Software\Classes\($APP_NAME)\shell\open\command' /ve /t REG_SZ /d $open_cmd /f

	# Associate extensions (probably wont work)
	for ext in (get-extensions) {
		print $"  assoc ($ext)=($APP_NAME)"
		^reg add $'HKCU\Software\Classes\($ext)' /ve /t REG_SZ /d $APP_NAME /f

	}

	let editor_val = $'"($exe)" ($PROGRAM_COMMAND)'
	print $"Setting EDITOR=($editor_val)"
	^reg add "HKCU\\Environment" /v EDITOR /t REG_SZ /d $editor_val /f
	^reg add "HKCU\\Environment" /v VISUAL /t REG_SZ /d $editor_val /f

	print ""
	print "Windows installation complete."
	print "NOTE: For some file types, Windows may require you to right-click a file,"
	print "      choose 'Open with' > 'Choose another app', select tasqer, and check"
	print "      'Always use this app'. The assoc/ftype registration covers most cases."
	print "NOTE: You may need to sign out and back in for EDITOR/VISUAL to take effect"
	print "      in new terminal sessions."
}

# ---------------------------------------------------------------------------
# Install: Linux
# ---------------------------------------------------------------------------

def install-linux [install_path: string] {
	let bin = $install_path | path join $PROGRAM_NAME
	let symlink = get-symlink-path

	# Symlink to PATH
	if ($symlink | path exists) {
		rm $symlink
	}
	print $"Symlinking ($bin) -> ($symlink)"
	ln -s $bin $symlink

	# Create .desktop file
	let desktop_dir = "~/.local/share/applications" | path expand
	mkdir $desktop_dir
	let desktop_file = $desktop_dir | path join $"($PROGRAM_NAME).desktop"

	let mime_types = get-mime-types

	let desktop_content = $"[Desktop Entry]
Type=Application
Name=($APP_NAME)
Comment=($APP_NAME) text editor
Exec=($PROGRAM_NAME) ($PROGRAM_COMMAND) %f
Terminal=false
NoDisplay=true
Categories=TextEditor;Development;Utility;
MimeType=($mime_types | str join ";");
"
	print $"Writing ($desktop_file)"
	$desktop_content | save -f $desktop_file

	if (which update-desktop-database | is-not-empty) {
		# Update desktop database
		print "Updating desktop database..."
		^update-desktop-database $desktop_dir
	}

	if (which xdg-mime | is-not-empty) {
		for mime in $mime_types {
			print $"  xdg-mime default tasqer.desktop ($mime)"
			^xdg-mime default tasqer.desktop $mime
		}
	}

	update-profile ~/.profile

	print ""
	print "Linux installation complete."
	print "Run `source ~/.profile` or start a new shell for EDITOR/VISUAL to take effect."
}

# ---------------------------------------------------------------------------
# Install: macOS
# ---------------------------------------------------------------------------

def install-macos [install_path: string] {
	let bin = $install_path | path join $PROGRAM_NAME
	let symlink = get-symlink-path

	# Symlink to PATH
	if ($symlink | path exists) {
		rm $symlink
	}
	print $"Symlinking ($bin) -> ($symlink)"
	^ln -sf $bin $symlink

	# Build Tasqer.app bundle
	let app_path = "~/Applications" | path expand | path join $"($APP_NAME).app"
	let contents = $app_path | path join "Contents"
	let macos_dir = $contents | path join "MacOS"

	mkdir $macos_dir

	# Create the launcher script
	let launcher_template_path = $BUILD_SCRIPT_LOCATION | path join macos_launcher main.m
	let launcher_log_path = $macos_dir | path join app.log
	let launcher_path = $macos_dir | path join $APP_NAME
	print $"Compiling ($launcher_path)"
	open $launcher_template_path
		| str replace "<APP_BIN_PATH>" $bin
		| str replace "<APP_COMMAND>" $PROGRAM_COMMAND
		| str replace "<APP_LOG_PATH>" $launcher_log_path
		| clang -x objective-c -fobjc-arc -framework Cocoa -o $launcher_path -

	# Build CFBundleDocumentTypes plist entries
	# Group extensions by UTType
	let doc_types = $FILE_TYPES
	| transpose key value
	| each {|it|
		let ext_bare = $it.key | str replace "." ""
		let uttype = $it.value.UTType
$"		<dict>
			<key>CFBundleTypeExtensions</key>
			<array>
				<string>($ext_bare)</string>
			</array>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>($uttype)</string>
			</array>
		</dict>"
	}
	| str join (char newline)

	let info_plist = $'<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.($PROGRAM_NAME).editor</string>
	<key>CFBundleName</key>
	<string>($APP_NAME)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleExecutable</key>
	<string>($APP_NAME)</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleDocumentTypes</key>
	<array>
($doc_types)
	</array>
</dict>
</plist>'

	let plist_path = $contents | path join "Info.plist"
	print $"Writing ($plist_path)"
	$info_plist | save -f $plist_path

	# Register the app with Launch Services
	print $"Registering ($APP_NAME).app with Launch Services..."
	run-external /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister "-f" $app_path

	# Use duti to set defaults if available
	if (which duti | is-not-empty) {
		let uttypes = get-uttypes
		for uttype in $uttypes {
			print $"  duti -s com.($PROGRAM_NAME).editor ($uttype) all"
			try { run-external duti "-s" $"com.($PROGRAM_NAME).editor" $uttype "all" }
		}
		for ext in (get-extensions) {
			let ext = $ext | str replace "." ""
			print $"  duti -s com.($PROGRAM_NAME).editor ($ext) all"
			try { run-external duti "-s" $"com.($PROGRAM_NAME).editor" $ext "all" }
		}
	} else {
		print ""
		print $"NOTE: 'duti' is not installed. To set ($PROGRAM_NAME) as the default editor for"
		print "      all registered file types, install duti (brew install duti) and run:"
		print "      nu build.nu install"
		print "      Or manually set Tasqer.app as the default via Finder > Get Info."
	}

	update-profile ~/.zprofile

	print ""
	print "macOS installation complete."
	print "Run `source ~/.zprofile` or start a new shell for EDITOR/VISUAL to take effect."
}

# ---------------------------------------------------------------------------
# Uninstall: Windows
# ---------------------------------------------------------------------------

def uninstall-windows [install_path: string] {
	# Remove file type associations
	print "Removing file type associations..."
	for ext in (get-extensions) {
		# Only remove if currently set to Tasqer
		try {
			let current = run-external cmd "/c" $"assoc ($ext)" | str trim
			if ($current | str contains $APP_NAME) {
				run-external cmd "/c" $"assoc ($ext)="
				print $"  Removed ($ext)"
			}
		}
	}

	# Remove ftype
	print $"Removing ftype ($APP_NAME)..."
	try { run-external cmd "/c" $"ftype ($APP_NAME)=" }

	# Remove EDITOR/VISUAL
	print "Removing EDITOR and VISUAL environment variables..."
	# Remove only if env is set to tasqer
	try { ^reg delete "HKCU\\Environment" /v EDITOR /f }
	try { ^reg delete "HKCU\\Environment" /v VISUAL /f }

	# Remove install directory
	if ($install_path | path exists) {
		print $"Removing ($install_path)..."
		rm -rf $install_path
	}

	print ""
	print "Windows uninstall complete."
	print "NOTE: You may need to sign out and back in for env changes to take effect."
}

# ---------------------------------------------------------------------------
# Uninstall: Linux
# ---------------------------------------------------------------------------

def uninstall-linux [install_path: path] {
	# Remove desktop file
	let desktop_file = "~/.local/share/applications" | path expand  | path join $"($PROGRAM_NAME).desktop"
	if ($desktop_file | path exists) {
		print $"Removing ($desktop_file)"
		rm $desktop_file
		if (which update-desktop-database | is-not-empty) {
			run-external update-desktop-database ("~/.local/share/applications" | path expand)
		}
	}

	# Remove symlink
	let symlink = get-symlink-path
	if ($symlink | path exists) {
		print $"Removing symlink ($symlink)"
		rm $symlink
	}

	update-profile ~/.profile --remove-only

	# Remove install directory
	if ($install_path | path exists) {
		print $"Removing ($install_path)..."
		rm -rf $install_path
	}

	print ""
	print "Linux uninstall complete."
}

# ---------------------------------------------------------------------------
# Uninstall: macOS
# ---------------------------------------------------------------------------

def uninstall-macos [install_path: string] {
	# Remove .app bundle
	let app_path = $install_path | path join $"($APP_NAME).app"
	if ($app_path | path exists) {
		print $"Removing ($app_path)"
		rm -rf $app_path
	}

	# Remove symlink
	let symlink = get-symlink-path
	if ($symlink | path exists) {
		print $"Removing symlink ($symlink)"
		rm $symlink
	}

	update-profile "~/.zprofile" --remove-only

	# Remove install directory
	if ($install_path | path exists) {
		print $"Removing ($install_path)..."
		rm -rf $install_path
	}

	print ""
	print "macOS uninstall complete."
}

# ---------------------------------------------------------------------------
# Public commands
# ---------------------------------------------------------------------------

export def install [--install-path: string, --build (-b)] {
	if $build {
		main
	}
	let path = if ($install_path | is-empty) { get-default-install-path } else { $install_path }
	let os = get-os

	print $"Installing ($PROGRAM_NAME) to ($path) on ($os)..."
	install-copy-files $path

	match $os {
		"Windows_NT" => { install-windows $path },
		"Linux" => { install-linux $path },
		"Darwin" => { install-macos $path },
		_ => {
			print $"Unsupported OS: ($os). Files were copied but no registration was performed."
		}
	}

	print ""
	print "Done!"
}
export alias "main install" = install

export def "main uninstall" [--install-path: string] {
	let path = if ($install_path | is-empty) { get-default-install-path } else { $install_path }
	let os = get-os

	print $"Uninstalling ($PROGRAM_NAME) from ($path) on ($os)..."

	match $os {
		"Windows_NT" => { uninstall-windows $path },
		"Linux" => { uninstall-linux $path },
		"Darwin" => { uninstall-macos $path },
		_ => {
			print $"Unsupported OS: ($os). Removing files only."
			if ($path | path exists) {
				rm -rf $path
			}
		}
	}

	print ""
	print "Done!"
}
export alias "main uninstall" = uninstall
