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
