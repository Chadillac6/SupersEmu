import Foundation

public struct PairingRequestIdentity: Equatable, Sendable {
    public let generation: Int
    public let source: String

    public init(generation: Int, source: String) {
        self.generation = generation
        self.source = source
    }

    public func matches(generation: Int, source: String) -> Bool {
        self.generation == generation && self.source == source
    }
}

public struct PairingFlowIdentity: Equatable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }

    public func matches(current: PairingFlowIdentity?) -> Bool {
        self == current
    }
}
