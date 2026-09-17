import Foundation

/// Storage for what the SDK has to remember between launches: the persistent
/// anonymous shopper UUID and the device clock correction.
///
/// The id **must** survive app restarts: it is the only thing that reopens a
/// shopper's conversations. It should **not** survive reinstallation — a new id
/// simply has no history, which is preferable to handing one device owner the
/// conversations of the previous one.
///
/// The clock correction is a convenience: without it a device with a skewed
/// clock pays one rejected mint per launch to learn the skew again. The two
/// clock methods have default implementations that remember nothing, so a store
/// written for the id alone keeps working.
///
/// Implement this to keep the values somewhere of your own; the SDK ships
/// ``TalqynUserDefaultsIDStore`` and ``TalqynInMemoryUserIDStore``.
///
/// - Note: Called from arbitrary threads. Implementations must be thread-safe.
public protocol TalqynUserIDStore: Sendable {
    /// Returns the stored shopper UUID, or `nil` if none has been stored yet.
    func loadUserID() -> UUID?

    /// Stores the shopper UUID, replacing any previous value.
    ///
    /// - Parameter id: The UUID to persist, or `nil` to forget the current one.
    func saveUserID(_ id: UUID?)

    /// Returns the stored device clock correction, in seconds, or `nil` if none
    /// has been stored yet.
    func loadClockOffset() -> TimeInterval?

    /// Stores the device clock correction: server clock minus device clock, in
    /// seconds.
    ///
    /// - Parameter offset: The correction to persist, or `nil` to forget it.
    func saveClockOffset(_ offset: TimeInterval?)
}

public extension TalqynUserIDStore {
    /// Remembers nothing: the correction is learned again on the next launch.
    func loadClockOffset() -> TimeInterval? { nil }

    /// Remembers nothing.
    func saveClockOffset(_ offset: TimeInterval?) {}
}

/// A ``TalqynUserIDStore`` backed by `UserDefaults`. The default store.
///
/// Deliberately not the Keychain: the shopper id is not a secret — it is
/// asserted by the device and verified by nobody — and Keychain items outlive
/// app deletion, which would hand a reinstalling device the previous owner's
/// history. If history has to follow a shopper across devices, issue the UUID
/// from your backend and pass it through ``TalqynDeviceIdentity/user(_:)``
/// instead.
public final class TalqynUserDefaultsIDStore: TalqynUserIDStore, @unchecked Sendable {
    // @unchecked Sendable: UserDefaults is thread-safe but not declared Sendable.
    private let defaults: UserDefaults
    private let key: String
    /// Derived from ``key`` so two stores with different keys — two
    /// storefronts in one app — do not share a correction.
    private var clockOffsetKey: String { key + ".clock_offset" }

    /// Creates a store backed by `UserDefaults`.
    ///
    /// - Parameters:
    ///   - defaults: The defaults database to use. Pass an app-group suite to
    ///     share the shopper id with extensions.
    ///   - key: The defaults key. Point it at an existing key to adopt an id
    ///     your app already generated. The clock correction lives under the
    ///     same key with a `.clock_offset` suffix.
    public init(defaults: UserDefaults = .standard, key: String = "talqyn.user_id") {
        self.defaults = defaults
        self.key = key
    }

    /// Returns the stored shopper UUID, or `nil` if the key is absent or holds a
    /// value that is not a UUID.
    public func loadUserID() -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    /// Writes the shopper UUID to the defaults database.
    ///
    /// - Parameter id: The UUID to persist, or `nil` to remove the key.
    public func saveUserID(_ id: UUID?) {
        guard let id else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(id.uuidString, forKey: key)
    }

    /// Returns the stored clock correction, or `nil` if none was stored.
    public func loadClockOffset() -> TimeInterval? {
        defaults.object(forKey: clockOffsetKey) as? TimeInterval
    }

    /// Writes the clock correction to the defaults database.
    ///
    /// - Parameter offset: The correction to persist, or `nil` to remove the key.
    public func saveClockOffset(_ offset: TimeInterval?) {
        guard let offset else {
            defaults.removeObject(forKey: clockOffsetKey)
            return
        }
        defaults.set(offset, forKey: clockOffsetKey)
    }
}

/// A ``TalqynUserIDStore`` that keeps its values in memory only.
///
/// For tests, and for storefronts that manage the shopper id themselves and only
/// need the SDK to hold it for the lifetime of the process.
public final class TalqynInMemoryUserIDStore: TalqynUserIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var id: UUID?
    private var clockOffset: TimeInterval?

    /// Creates an in-memory store.
    ///
    /// - Parameter id: The initial shopper UUID, if any.
    public init(id: UUID? = nil) {
        self.id = id
    }

    /// Returns the shopper UUID held in memory, or `nil` if none was stored.
    public func loadUserID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return id
    }

    /// Replaces the shopper UUID held in memory.
    ///
    /// - Parameter id: The UUID to keep, or `nil` to forget the current one.
    public func saveUserID(_ id: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        self.id = id
    }

    /// Returns the clock correction held in memory, or `nil` if none was stored.
    public func loadClockOffset() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return clockOffset
    }

    /// Replaces the clock correction held in memory.
    ///
    /// - Parameter offset: The correction to keep, or `nil` to forget it.
    public func saveClockOffset(_ offset: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        clockOffset = offset
    }
}
