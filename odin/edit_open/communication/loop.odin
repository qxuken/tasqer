package communication

import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import zmq "edit_open:zeromq"

loop :: proc(state: ^CommunucationState) -> (ok: bool) {
    for !state.quit {
        free_all(context.temp_allocator)

        switch &v in state.role {
        case Leader:
            step_leader(state)
        case Follower:
            step_follower(state)
        case:
            join_network(state) or_return
        }
    }
    return true
}

step_leader :: proc(state: ^CommunucationState) {
    role := &state.role.(Leader)

    evt: zmq.Poller_Event
    zmq.poller_wait(state.role.(Leader).poller, &evt, cast(c.long)time.duration_milliseconds(POLL_INTERVAL))
    if evt.events == .POLLIN {
        msg: string
        more := true
        for more {
            msg, more = zmq.recv_string(evt.socket, allocator = context.temp_allocator)
            log.infof("Recieved: \"%v\"", msg)
            log.infof("Sending: \"%v\"", msg)
            zmq.send_string(role.publisher_socket, msg, .SNDMORE if more else .None)
            role.last_sent = time.now()
        }
    }

    now := time.now()
    if time.diff(role.last_sent, now) > HEARTBEAT_INTERVAL {
        role.last_sent = now
        log.info(`Sending: "tick"`)
        zmq.send_string(state.role.(Leader).publisher_socket, "tick")
    }
}

step_follower :: proc(state: ^CommunucationState) {
    role := &state.role.(Follower)

    evt: zmq.Poller_Event
    zmq.poller_wait(state.role.(Follower).poller, &evt, cast(c.long)time.duration_milliseconds(POLL_INTERVAL))
    if evt.events == .POLLIN && evt.socket != nil {
        msg: string
        more := true
        for more {
            role.last_seen_leader = time.now()
            msg, more = zmq.recv_string(evt.socket, allocator = context.temp_allocator)
            log.infof("Recieved: \"%v\"", msg)
        }
    } else if evt.fd != -1 {
        buf: [512]u8
        data, err := os.read(cast(os.Handle)evt.fd, buf[:])
        if err != nil {
            log.errorf("STDIO: \"%v\"", os.error_string(err))
            return
        }
        {
            messages := strings.split(string(buf[:data - 1]), "|", allocator = context.temp_allocator)
            for msg, i in messages {
                log.infof("STDIO: \"%v\"", msg)
                if msg == "q" {
                    state.quit = true
                } else {
                    zmq.send_string(role.push_socket, msg, .SNDMORE if i < len(messages) - 1 else .None)
                }
            }
        }
    }

    if time.since(role.last_seen_leader) > (HEARTBEAT_TIMEOUT + role.rand_offset) {
        log.info("Taking over attempt")
        destroy_role(state.role)
        state.role = nil
    }
}
