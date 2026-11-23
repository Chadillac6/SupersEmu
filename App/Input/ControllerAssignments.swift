/// Device IDs are valid for a connection, not a persisted controller profile.
struct ControllerAssignments {
    private(set) var slots: [String?]
    private var connected: Set<String> = []

    init(portCount: Int) {
        slots = Array(repeating: nil, count: portCount)
    }

    mutating func update(connectedIDs: [String]) {
        let next = Set(connectedIDs)
        for port in slots.indices {
            if let id = slots[port], !next.contains(id) {
                slots[port] = nil
            }
        }
        let openPorts = slots.indices.filter { slots[$0] == nil }
        let newcomers = connectedIDs.filter { !connected.contains($0) }
        for (port, id) in zip(openPorts, newcomers) {
            slots[port] = id
        }
        connected = next
    }

    mutating func assign(_ id: String?, to port: Int) {
        guard slots.indices.contains(port), slots[port] != id else { return }
        if let id {
            guard connected.contains(id) else { return }
            if let previous = slots.firstIndex(of: id) {
                slots[previous] = slots[port]
            }
        }
        slots[port] = id
    }
}
