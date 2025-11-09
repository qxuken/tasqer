package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import eo "edit_open"
import comm "edit_open:communication"


main :: proc() {
    context.logger = log.create_console_logger(lowest = log.Level.Debug when ODIN_DEBUG else log.Level.Info)

    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        context.allocator = mem.tracking_allocator(&track)

        defer {
            if len(track.allocation_map) > 0 {
                fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
                for _, entry in track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            if len(track.bad_free_array) > 0 {
                fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
                for entry in track.bad_free_array {
                    fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
                }
            }
            mem.tracking_allocator_destroy(&track)
        }

        eo.report_run_params()
    } else {
        _ :: mem
        _ :: fmt
        _ :: eo
    }

    state := comm.new_state()
    defer comm.destroy_state(&state)
    if !comm.loop(&state) {
        os.exit(1)
    }
}
