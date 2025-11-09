package communication

import "core:c"
import "core:crypto"
import "core:encoding/uuid"
import "core:log"
import "core:math/rand"
import "core:time"
import zmq "edit_open:zeromq"

HEARTBEAT_TIMEOUT :: time.Second * 2
HEARTBEAT_INTERVAL :: HEARTBEAT_TIMEOUT / 2
HEARTBEAT_INTERVAL_MS := cast(c.long)time.duration_milliseconds(HEARTBEAT_INTERVAL)
POLL_INTERVAL :: HEARTBEAT_INTERVAL

Leader :: struct {
    publisher_socket: ^zmq.Socket,
    pull_socket:      ^zmq.Socket,
    poller:           ^zmq.Poller,
    last_sent:        time.Time,
}

Follower :: struct {
    subscriber_socket: ^zmq.Socket,
    push_socket:       ^zmq.Socket,
    poller:            ^zmq.Poller,
    last_seen_leader:  time.Time,
    rand_offset:       time.Duration,
}

Role :: union {
    Leader,
    Follower,
}

CommunucationState :: struct {
    id:          [36]u8,
    zmq_context: ^zmq.Context,
    role:        Role,
    quit:        bool,
}

new_state :: proc() -> (res: CommunucationState) {
    log.debug("Begin")
    res.zmq_context = zmq.ctx_new()
    {
        context.random_generator = crypto.random_generator()
        uuid.to_string_buffer(uuid.generate_v7(), res.id[:])
    }
    log.debug("State created")
    return
}

udpate_role :: proc(state: ^CommunucationState, role: Role) {
    log.debugf("New role %v", role)
    destroy_role(state.role)
    state.role = role
    #partial switch &v in state.role {
    case Follower:
        v.rand_offset = time.Millisecond * cast(time.Duration)(time.duration_milliseconds(HEARTBEAT_INTERVAL) * rand.float64_range(0, 2))
        v.last_seen_leader = time.now()
    }
}

destroy_role :: proc(role: Role) {
    log.debug("destroy_role", role)
    switch &v in role {
    case Leader:
        if v.publisher_socket != nil do zmq.close(v.publisher_socket)
        if v.pull_socket != nil do zmq.close(v.pull_socket)
        if v.poller != nil do zmq.poller_destroy(&v.poller)
        v.publisher_socket = nil
        v.pull_socket = nil
    case Follower:
        if v.subscriber_socket != nil do zmq.close(v.subscriber_socket)
        if v.push_socket != nil do zmq.close(v.push_socket)
        if v.poller != nil do zmq.poller_destroy(&v.poller)
        v.subscriber_socket = nil
        v.push_socket = nil
    }
}

destroy_state :: proc(state: ^CommunucationState) {
    log.debug("Begin")
    destroy_role(state.role)
    state.role = nil
    if state.zmq_context != nil {
        zmq.ctx_term(state.zmq_context)
        state.zmq_context = nil
    }
    log.debug("State destroyed")
}
