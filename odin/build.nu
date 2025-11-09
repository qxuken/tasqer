export def main [--run (-r), --no-vet, --release, ...run_args] {
	let out = 'dist/edit_open.exe'

	mut args = ['build' '.' '-collection:edit_open=edit_open' $'-out:($out)']
	if not $no_vet {
		$args = $args | append '-vet'
	}
	if not $release {
		$args = $args | append '-debug'
	}

	mkdir ./dist
	run-external odin ...$args

	if $run or ($run_args | is-not-empty) {
		run-external $out ...$run_args
	}
}
