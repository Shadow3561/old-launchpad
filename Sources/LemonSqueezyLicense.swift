import Foundation
import Security

struct LemonSqueezyLicenseStatus: Codable {
    let active: Bool
    let email: String
    let instanceID: String
    let activatedAt: Date
}

struct LemonSqueezyTrialStatus {
    let startedAt: Date
    let expiresAt: Date
    let isActive: Bool
    let isExpired: Bool
    let remainingDays: Int
}

enum LemonSqueezyLicenseError: LocalizedError {
    case missingInput
    case offline
    case network(String)
    case invalidResponse
    case api(String)
    case keychain(String)
    case keychainSaveAndDeactivationFailed(String)
    case trialExpired
    case emailMismatch
    case emailMismatchDeactivationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingInput:
            "Bitte Lizenzschlüssel und E-Mail-Adresse eingeben."
        case .offline:
            "Keine Internetverbindung. Bitte verbinde dich mit dem Internet und versuche es erneut."
        case .network(let message):
            "Netzwerkfehler: \(message)"
        case .invalidResponse:
            "Die Antwort des Lizenzservers konnte nicht gelesen werden."
        case .api(let message):
            message
        case .keychain(let message):
            "Der Lizenzstatus konnte nicht aus dem Schlüsselbund gelesen oder gespeichert werden: \(message)"
        case .keychainSaveAndDeactivationFailed(let message):
            "Der Lizenzstatus konnte nicht im Schlüsselbund gespeichert werden. Außerdem konnte die Aktivierung nicht zurückgenommen werden: \(message)"
        case .trialExpired:
            "Der 30-Tage-Testzeitraum wurde bereits genutzt und ist abgelaufen. Bitte aktiviere eine Lizenz."
        case .emailMismatch:
            "Die E-Mail-Adresse stimmt nicht mit dem Kauf der Lizenz überein."
        case .emailMismatchDeactivationFailed(let message):
            "Die E-Mail-Adresse stimmt nicht mit dem Kauf überein. Die dabei angelegte Aktivierung konnte nicht zurückgenommen werden: \(message)"
        }
    }
}

enum LemonSqueezyLicense {
    private static let keychainService = Bundle.main.bundleIdentifier ?? "local.deepal.oldlaunchpad"
    private static let keychainAccount = "license-activation-status"
    private static let firstInstallKeychainAccount = "first-install-date"
    private static let trialAcceptedKeychainAccount = "trial-accepted"
    private static let trialDuration: TimeInterval = 30 * 24 * 60 * 60
    private static let activateURL = URL(string: "https://api.lemonsqueezy.com/v1/licenses/activate")!
    private static let deactivateURL = URL(string: "https://api.lemonsqueezy.com/v1/licenses/deactivate")!

    private struct ActivationResponse: Decodable {
        let activated: Bool
        let error: String?
        let instance: Instance?
        let meta: Metadata?

        struct Instance: Decodable {
            let id: String
        }

        struct Metadata: Decodable {
            let customerEmail: String?

            enum CodingKeys: String, CodingKey {
                case customerEmail = "customer_email"
            }
        }
    }

    private struct DeactivationResponse: Decodable {
        let deactivated: Bool
        let error: String?
    }

    static func activate(
        licenseKey: String,
        email: String,
        instanceName: String = "Old Launchpad auf diesem Mac",
        session: URLSession = .shared
    ) async throws -> LemonSqueezyLicenseStatus {
        let licenseKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !licenseKey.isEmpty, !email.isEmpty else {
            throw LemonSqueezyLicenseError.missingInput
        }

        var request = URLRequest(url: activateURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody([
            "license_key": licenseKey,
            "instance_name": instanceName
        ])
        let (data, response) = try await send(request, using: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LemonSqueezyLicenseError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LemonSqueezyLicenseError.api(
                "Der Lizenzserver hat die Anfrage mit HTTP \(httpResponse.statusCode) abgelehnt."
            )
        }

        let activation: ActivationResponse
        do {
            activation = try JSONDecoder().decode(ActivationResponse.self, from: data)
        } catch {
            throw LemonSqueezyLicenseError.invalidResponse
        }
        guard activation.activated else {
            throw LemonSqueezyLicenseError.api(activation.error ?? "Der Lizenzschlüssel konnte nicht aktiviert werden.")
        }
        guard let instanceID = activation.instance?.id,
              let customerEmail = activation.meta?.customerEmail else {
            throw LemonSqueezyLicenseError.invalidResponse
        }

        guard customerEmail.caseInsensitiveCompare(email) == .orderedSame else {
            do {
                try await deactivate(licenseKey: licenseKey, instanceID: instanceID, using: session)
            } catch {
                throw LemonSqueezyLicenseError.emailMismatchDeactivationFailed(error.localizedDescription)
            }
            throw LemonSqueezyLicenseError.emailMismatch
        }

        let status = LemonSqueezyLicenseStatus(
            active: true,
            email: customerEmail,
            instanceID: instanceID,
            activatedAt: Date()
        )
        do {
            try saveStatus(status)
        } catch {
            do {
                try await deactivate(licenseKey: licenseKey, instanceID: instanceID, using: session)
            } catch {
                throw LemonSqueezyLicenseError.keychainSaveAndDeactivationFailed(error.localizedDescription)
            }
            throw error
        }
        return status
    }

    static func saveStatus(_ status: LemonSqueezyLicenseStatus) throws {
        let data = try JSONEncoder().encode(status)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus)
        }
    }

    static func savedStatus() throws -> LemonSqueezyLicenseStatus? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }
        do {
            return try JSONDecoder().decode(LemonSqueezyLicenseStatus.self, from: data)
        } catch {
            throw LemonSqueezyLicenseError.keychain("Der gespeicherte Lizenzstatus ist beschädigt.")
        }
    }

    static func startOrResumeTrial(now: Date = Date()) throws -> LemonSqueezyTrialStatus {
        let startedAt: Date
        if let storedStart = try firstInstallDate() {
            startedAt = storedStart
        } else {
            let created = try addFirstInstallDate(now)
            if created {
                startedAt = now
            } else if let storedStart = try firstInstallDate() {
                startedAt = storedStart
            } else {
                throw LemonSqueezyLicenseError.keychain("Der Testzeitraum konnte nicht gelesen werden.")
            }
        }

        let expiresAt = startedAt.addingTimeInterval(trialDuration)
        guard now < expiresAt else {
            throw LemonSqueezyLicenseError.trialExpired
        }
        try acceptTrial()
        return LemonSqueezyTrialStatus(
            startedAt: startedAt,
            expiresAt: expiresAt,
            isActive: true,
            isExpired: false,
            remainingDays: max(1, Int(ceil(expiresAt.timeIntervalSince(now) / 86_400)))
        )
    }

    static func initializeTrialStartDateIfNeeded(now: Date = Date()) throws {
        guard try firstInstallDate() == nil else { return }
        if try !addFirstInstallDate(now) {
            guard try firstInstallDate() != nil else {
                throw LemonSqueezyLicenseError.keychain("Der Testzeitraum konnte nicht gelesen werden.")
            }
        }
    }

    static func savedTrialStatus(now: Date = Date()) throws -> LemonSqueezyTrialStatus? {
        guard let startedAt = try firstInstallDate() else { return nil }
        let expiresAt = startedAt.addingTimeInterval(trialDuration)
        let isExpired = now >= expiresAt
        let isAccepted = try trialWasAccepted()
        let isActive = !isExpired && isAccepted
        return LemonSqueezyTrialStatus(
            startedAt: startedAt,
            expiresAt: expiresAt,
            isActive: isActive,
            isExpired: isExpired,
            remainingDays: max(0, Int(ceil(expiresAt.timeIntervalSince(now) / 86_400)))
        )
    }

    private static func firstInstallDate() throws -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: firstInstallKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let date = try? JSONDecoder().decode(Date.self, from: data) else {
            throw keychainError(status == errSecSuccess ? errSecDecode : status)
        }
        return date
    }

    private static func addFirstInstallDate(_ date: Date) throws -> Bool {
        let data = try JSONEncoder().encode(date)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: firstInstallKeychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw keychainError(status) }
        return true
    }

    private static func trialWasAccepted() throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: trialAcceptedKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess, result as? Data != nil else {
            throw keychainError(status)
        }
        return true
    }

    private static func acceptTrial() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: trialAcceptedKeychainAccount,
            kSecValueData as String: Data([1]),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw keychainError(status)
        }
    }

    private static func keychainError(_ status: OSStatus) -> LemonSqueezyLicenseError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .keychain(message)
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func deactivate(
        licenseKey: String,
        instanceID: String,
        using session: URLSession
    ) async throws {
        var request = URLRequest(url: deactivateURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody([
            "license_key": licenseKey,
            "instance_id": instanceID
        ])

        let (data, response) = try await send(request, using: session)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LemonSqueezyLicenseError.invalidResponse
        }
        let result = try JSONDecoder().decode(DeactivationResponse.self, from: data)
        guard result.deactivated else {
            throw LemonSqueezyLicenseError.api(result.error ?? "Die Aktivierung konnte nicht zurückgenommen werden.")
        }
    }

    private static func send(
        _ request: URLRequest,
        using session: URLSession
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed:
                throw LemonSqueezyLicenseError.offline
            default:
                throw LemonSqueezyLicenseError.network(error.localizedDescription)
            }
        } catch {
            throw LemonSqueezyLicenseError.network(error.localizedDescription)
        }
    }
}
