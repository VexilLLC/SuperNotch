import Foundation

/// Settings written by the app and read by the root helper.
public struct ChargeLimitConfiguration: Codable, Equatable, Sendable {
    public static let limitRange = 50...100
    public static let sailingRangeBounds = 1...20

    public var enabled: Bool
    public var limit: Int
    /// Turn the MagSafe light green while charging is held at the limit.
    public var controlsLED: Bool
    /// Keep charging while asleep. The helper cannot act during sleep, so this can pass the limit.
    public var chargesDuringSleep: Bool
    /// How far the battery may drift below the limit before charging resumes.
    public var sailingRange: Int
    /// A one-shot request to run from the battery until it falls to the limit.
    public var dischargeRequestedAt: Date?
    /// A one-shot request to charge to 100% once, ignoring the limit.
    public var topUpRequestedAt: Date?

    public init(
        enabled: Bool,
        limit: Int,
        controlsLED: Bool = true,
        chargesDuringSleep: Bool = false,
        sailingRange: Int = 3,
        dischargeRequestedAt: Date? = nil,
        topUpRequestedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.limit = min(Self.limitRange.upperBound, max(Self.limitRange.lowerBound, limit))
        self.controlsLED = controlsLED
        self.chargesDuringSleep = chargesDuringSleep
        self.sailingRange = min(Self.sailingRangeBounds.upperBound, max(Self.sailingRangeBounds.lowerBound, sailingRange))
        self.dischargeRequestedAt = dischargeRequestedAt
        self.topUpRequestedAt = topUpRequestedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 80,
            controlsLED: try container.decodeIfPresent(Bool.self, forKey: .controlsLED) ?? true,
            chargesDuringSleep: try container.decodeIfPresent(Bool.self, forKey: .chargesDuringSleep) ?? false,
            sailingRange: try container.decodeIfPresent(Int.self, forKey: .sailingRange) ?? 3,
            dischargeRequestedAt: try container.decodeIfPresent(Date.self, forKey: .dischargeRequestedAt),
            topUpRequestedAt: try container.decodeIfPresent(Date.self, forKey: .topUpRequestedAt)
        )
    }

    public static let disabled = ChargeLimitConfiguration(enabled: false, limit: 80)

    /// The level at which charging resumes after being held.
    public var resumeLevel: Int { max(0, limit - sailingRange) }
}

/// What the helper last applied, written for the app to display.
public struct ChargeLimitStatus: Codable, Equatable, Sendable {
    public var helperVersion: Int
    public var scheme: ChargingControlScheme?
    public var supportsLED: Bool
    public var supportsDischarge: Bool
    public var enabled: Bool
    public var limit: Int
    public var chargingInhibited: Bool
    public var adapterDisabled: Bool
    public var discharging: Bool
    public var toppingUp: Bool
    public var pausedForSleep: Bool
    public var batteryPercent: Int?
    /// A charger is physically connected, even if it has been switched off.
    public var adapterConnected: Bool
    public var updatedAt: Date
    public var lastError: String?

    public init(
        helperVersion: Int = ChargeLimitPaths.helperVersion,
        scheme: ChargingControlScheme?,
        supportsLED: Bool,
        supportsDischarge: Bool = false,
        enabled: Bool,
        limit: Int,
        chargingInhibited: Bool,
        adapterDisabled: Bool = false,
        discharging: Bool = false,
        toppingUp: Bool = false,
        pausedForSleep: Bool,
        batteryPercent: Int?,
        adapterConnected: Bool,
        updatedAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.helperVersion = helperVersion
        self.scheme = scheme
        self.supportsLED = supportsLED
        self.supportsDischarge = supportsDischarge
        self.enabled = enabled
        self.limit = limit
        self.chargingInhibited = chargingInhibited
        self.adapterDisabled = adapterDisabled
        self.discharging = discharging
        self.toppingUp = toppingUp
        self.pausedForSleep = pausedForSleep
        self.batteryPercent = batteryPercent
        self.adapterConnected = adapterConnected
        self.updatedAt = updatedAt
        self.lastError = lastError
    }

    /// Tolerates status files from older helpers, so the app can offer an update.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        helperVersion = try container.decodeIfPresent(Int.self, forKey: .helperVersion) ?? 0
        scheme = try? container.decodeIfPresent(ChargingControlScheme.self, forKey: .scheme)
        supportsLED = try container.decodeIfPresent(Bool.self, forKey: .supportsLED) ?? false
        supportsDischarge = try container.decodeIfPresent(Bool.self, forKey: .supportsDischarge) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 80
        chargingInhibited = try container.decodeIfPresent(Bool.self, forKey: .chargingInhibited) ?? false
        adapterDisabled = try container.decodeIfPresent(Bool.self, forKey: .adapterDisabled) ?? false
        discharging = try container.decodeIfPresent(Bool.self, forKey: .discharging) ?? false
        toppingUp = try container.decodeIfPresent(Bool.self, forKey: .toppingUp) ?? false
        pausedForSleep = try container.decodeIfPresent(Bool.self, forKey: .pausedForSleep) ?? false
        batteryPercent = try container.decodeIfPresent(Int.self, forKey: .batteryPercent)
        adapterConnected = try container.decodeIfPresent(Bool.self, forKey: .adapterConnected) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// The charging and adapter state the helper should apply.
public struct ChargeLimitAction: Equatable, Sendable {
    public var inhibitCharging: Bool
    public var disableAdapter: Bool
    public var discharging: Bool
    public var toppingUp: Bool
    /// The discharge request has finished and should not run again.
    public var dischargeFinished: Bool
    /// The top-up request has finished and should not run again.
    public var topUpFinished: Bool

    public static let normal = ChargeLimitAction(inhibitCharging: false, disableAdapter: false, discharging: false, toppingUp: false, dischargeFinished: false, topUpFinished: false)
}

public enum ChargeLimitPolicy {
    /// The default sailing range.
    public static let resumeHysteresis = 3
    /// Requests older than this are ignored, so a forgotten discharge or top-up cannot linger.
    public static let requestLifetime: TimeInterval = 48 * 3_600
    /// Never keep the adapter off below this level, whatever the settings say.
    public static let minimumDischargeLevel = 20

    /// Whether charging should be held, given the current battery level and
    /// whether it is already held. Held charge resumes once the battery sails
    /// down to `limit - sailingRange`.
    public static func shouldInhibit(configuration: ChargeLimitConfiguration, batteryPercent: Int?, currentlyInhibited: Bool) -> Bool {
        guard configuration.enabled, configuration.limit < 100, let batteryPercent else { return false }
        if batteryPercent >= configuration.limit { return true }
        if currentlyInhibited, batteryPercent > configuration.resumeLevel { return true }
        return false
    }

    public static func isRequestActive(_ requestedAt: Date?, finishedFor: Date?, now: Date = Date()) -> Bool {
        guard let requestedAt, requestedAt != finishedFor else { return false }
        let age = now.timeIntervalSince(requestedAt)
        return age >= -300 && age < requestLifetime
    }

    /// Resolves the limit, sailing, discharge and top-up rules into one action.
    public static func decide(
        configuration: ChargeLimitConfiguration,
        batteryPercent: Int?,
        pluggedIn: Bool,
        currentlyInhibited: Bool,
        dischargeActive: Bool,
        topUpActive: Bool,
        supportsAdapterControl: Bool
    ) -> ChargeLimitAction {
        guard configuration.enabled, let batteryPercent else { return .normal }
        var action = ChargeLimitAction.normal

        if topUpActive {
            if batteryPercent >= 100 {
                action.topUpFinished = true
            } else {
                // Charging to full wins over everything else, including a discharge.
                action.toppingUp = true
                action.dischargeFinished = dischargeActive
                return action
            }
        }

        if dischargeActive {
            if batteryPercent <= configuration.limit || batteryPercent <= minimumDischargeLevel || !supportsAdapterControl {
                action.dischargeFinished = true
            } else {
                action.discharging = true
                action.inhibitCharging = true
                // Unplugged, the battery already discharges on its own.
                action.disableAdapter = pluggedIn
                return action
            }
        }

        action.inhibitCharging = shouldInhibit(configuration: configuration, batteryPercent: batteryPercent, currentlyInhibited: currentlyInhibited || action.dischargeFinished)
        return action
    }

    /// The MagSafe light state to request. Green only while held on the adapter;
    /// otherwise macOS keeps control of the light.
    public static func led(configuration: ChargeLimitConfiguration, inhibited: Bool, adapterConnected: Bool) -> MagSafeLED {
        guard configuration.enabled, configuration.controlsLED, inhibited, adapterConnected else { return .system }
        return .green
    }

    /// Whether to pause charging before the Mac sleeps, so it cannot pass the limit unattended.
    public static func shouldPauseForSleep(configuration: ChargeLimitConfiguration, currentlyInhibited: Bool) -> Bool {
        configuration.enabled && configuration.limit < 100 && !configuration.chargesDuringSleep && !currentlyInhibited
    }
}

public enum ChargeLimitPaths {
    /// Bump when helper behavior or the status format changes, so the app offers an update.
    public static let helperVersion = 2
    public static let label = "org.supernotch.chargehelper"
    public static let helperExecutable = "/Library/PrivilegedHelperTools/org.supernotch.chargehelper"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/org.supernotch.chargehelper.plist"
    /// Root-owned; the helper writes status here.
    public static let stateDirectory = "/Library/Application Support/SuperNotch/ChargeLimit"
    public static let statusFile = stateDirectory + "/status.json"
    /// Root-owned record of finished discharge and top-up requests.
    public static let requestStateFile = stateDirectory + "/requests.json"
    /// Owned by the user who installed the helper; the app writes settings here.
    public static let settingsDirectory = stateDirectory + "/Settings"
    public static let configurationFile = settingsDirectory + "/config.json"

    public static func launchDaemonPlistData() throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperExecutable, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "StandardErrorPath": "/var/log/supernotch-chargehelper.log"
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
