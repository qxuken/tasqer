package communication

import "core:c"
import "core:log"
import "core:os"
import zmq "edit_open:zeromq"

ADDR_SUB :: #config(EDIT_ADDR_SUB, "tcp://127.0.0.1:53534")
ADDR_RPC :: #config(EDIT_ADDR_RPC, "tcp://127.0.0.1:53535")

Join_Result :: enum {
    Ok,
    Fatal,
    Failed,
}

join_network :: proc(state: ^CommunucationState) -> (ok: bool) {
    switch try_become_leader(state) {
    case .Failed:
        return try_become_follower(state) == .Ok
    case .Fatal:
        return false
    case .Ok:
        return true
    }
    unreachable()
}

try_become_leader :: proc(state: ^CommunucationState) -> (res: Join_Result = .Ok) {
    log.debug("Begin")
    role := Leader {
        publisher_socket = zmq.socket(state.zmq_context, .PUB),
        pull_socket      = zmq.socket(state.zmq_context, .PULL),
        poller           = zmq.poller_new(),
    }
    defer if res != .Ok {
        destroy_role(role)
    }
    zmq.poller_add(role.poller, role.pull_socket, nil, .POLLIN)

    log.debug("Bind to SUB")
    if rc := zmq.bind(role.publisher_socket, ADDR_SUB); rc != 0 {
        if zmq.errno() == zmq.EADDRINUSE {
            res = .Failed
            log.debug("zmq.bind(publisher_socket):", zmq.zmq_error_cstring())
        } else {
            res = .Fatal
            log.error("zmq.bind(publisher_socket):", zmq.zmq_error_cstring())
        }
        return
    }
    if !zmq.setsockopt_int(role.publisher_socket, .LINGER, 0) {
        res = .Fatal
        log.error("zmq.setsockopt_string(publisher_socket-LINGER):", zmq.zmq_error_cstring())
        return
    }

    log.debug("Bind to RPC")
    if rc := zmq.bind(role.pull_socket, ADDR_RPC); rc != 0 {
        res = .Fatal
        log.error("zmq.bind(reply):", zmq.zmq_error_cstring())
        return
    }
    if !zmq.setsockopt_int(role.pull_socket, .LINGER, 0) {
        res = .Fatal
        log.error("zmq.setsockopt_string(pull_socket-LINGER):", zmq.zmq_error_cstring())
        return
    }

    udpate_role(state, role)
    log.info("Become leader")
    return
}

try_become_follower :: proc(state: ^CommunucationState) -> (res: Join_Result) {
    log.debug("Begin")
    role := Follower {
        subscriber_socket = zmq.socket(state.zmq_context, .SUB),
        push_socket       = zmq.socket(state.zmq_context, .PUSH),
        poller            = zmq.poller_new(),
    }
    defer if res != .Ok {
        destroy_role(role)
    }
    zmq.poller_add(role.poller, role.subscriber_socket, nil, .POLLIN)
    zmq.poller_add(role.poller, role.push_socket, nil, .POLLIN)
    zmq.poller_add_fd(role.poller, cast(c.int)os.stdin, nil, .POLLIN)

    log.debug("Connect to SUB")
    if rc := zmq.connect(role.subscriber_socket, ADDR_SUB); rc != 0 {
        res = .Fatal
        log.error("zmq.connect(subscriber):", zmq.zmq_error_cstring())
        return
    }
    if !zmq.setsockopt_string(role.subscriber_socket, .SUBSCRIBE, "") {
        log.error("zmq.setsockopt_string(subscriber_socket-SUBSCRIBE):", zmq.zmq_error_cstring())
        return .Fatal
    }
    if !zmq.setsockopt_int(role.subscriber_socket, .LINGER, 0) {
        log.error("zmq.setsockopt_string(subscriber_socket-LINGER):", zmq.zmq_error_cstring())
        return .Fatal
    }

    log.debug("Connect to RPC")
    if rc := zmq.connect(role.push_socket, ADDR_RPC); rc != 0 {
        log.error("zmq.connect(request):", zmq.zmq_error_cstring())
        return .Fatal
    }
    if !zmq.setsockopt_string(role.push_socket, .IDENTITY, string(state.id[:])) {
        log.error("zmq.setsockopt_string(push_socket-IDENTITY):", zmq.zmq_error_cstring())
        return .Fatal
    }
    if !zmq.setsockopt_int(role.push_socket, .LINGER, 0) {
        log.error("zmq.setsockopt_string(push_socket-LINGER):", zmq.zmq_error_cstring())
        return .Fatal
    }

    udpate_role(state, role)
    log.info("Become follower")
    return .Ok
}
