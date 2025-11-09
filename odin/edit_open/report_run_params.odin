package edit_open

import "core:log"
import "core:os"

report_run_params :: proc() {
    cwd := os.get_current_directory()
    defer delete(cwd)

    log.debugf(`cwd  = "%v"`, cwd)
    log.debug("args =", os.args)
}
