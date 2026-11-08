//
//  SignIn.swift
//  Wazy
//
//  Native sign-in: the same GraphQL the Disney+ apps use, no web view. Registering a device gets an
//  anonymous token; logging in with email and password turns it into an account token; picking a
//  profile gives the token the browse and playback APIs want. Tokens last four hours; the refresh
//  token that comes with them renews the session between launches. The form is WazKit's.
//

import SwiftUI
import WazKit
import Security

@MainActor
final class DisneyAuth: CredentialSignIn {
    /// The public API key disneyplus.com's web app registers devices with.
    private static let apiKey = "ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84"
    private static let deviceEndpoint = URL(string: "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql")!
    private static let queryEndpoint = URL(string: "https://disney.api.edge.bamgrid.com/v1/public/graphql")!

    private static let registerDeviceQuery = "mutation ($registerDevice: RegisterDeviceInput!) { registerDevice(registerDevice: $registerDevice) { __typename } }"
    private static let loginQuery = "mutation login($input: LoginInput!) { login(login: $input) { account { profiles { id name attributes { kidsModeEnabled parentalControls { isPinProtected } } } } } }"
    private static let switchProfileQuery = "mutation switchProfile($input: SwitchProfileInput!) { switchProfile(switchProfile: $input) { account { activeProfile { id } } } }"
    private static let refreshQuery = "mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) { activeSession { sessionId } } }"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            "X-BAMSDK-Client-ID": "disney-svod-3d9324fc",
            "X-BAMSDK-Platform": "browser",
            "X-BAMSDK-Platform-Id": "browser",
            "X-BAMSDK-Version": "32.0",
            "X-Application-Version": "1.1.2",
        ]
        return URLSession(configuration: config)
    }()

    /// The account token `login` got; it only serves to switch profile.
    private var accountToken: String?
    private var credentials: Credentials?
    private let automatic: Bool
    private static var attemptedRecovery = false
    private static var recoveryTask: Task<Bool, Never>?

    let name = "Disney+"

    init(automatic: Bool = false) { self.automatic = automatic }

    private struct Credentials: Codable {
        let email: String
        let password: String
        var profileID: String?
    }

    private static var credentialKey: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.starplayrx.wazy.credentials",
         kSecAttrAccount as String: "disneyplus"]
    }

    private static func savedCredentials() -> Credentials? {
        var query = credentialKey
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(credentialKey as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = credentialKey
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DisneyError.badResponse("Keychain save \(status)") }
    }

    /// One automatic sign-in per run with the credentials saved in Keychain; false sends the user to the form.
    static func recover() async -> Bool {
        if let recoveryTask { return await recoveryTask.value }
        guard !attemptedRecovery else { return false }
        attemptedRecovery = true
        let task = Task { @MainActor in
            guard let saved = savedCredentials() else { return false }
            let auth = DisneyAuth(automatic: true)
            do {
                let profiles = try await auth.login(email: saved.email, password: saved.password)
                try Task.checkCancellation()
                guard let profile = profiles.first(where: { $0.id == saved.profileID }),
                      !profile.isPinProtected else { return false }
                try await auth.pick(profile, pin: nil)
                return true
            } catch { return false }
        }
        recoveryTask = task
        let result = await task.value
        recoveryTask = nil
        return result
    }

    static func stopRecovery() {
        attemptedRecovery = true
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// Email and password → the account's profiles. Nothing is stored until a profile is picked.
    func login(email: String, password: String) async throws -> [SignInProfile] {
        credentials = nil
        if !automatic { Self.stopRecovery() }
        let device = try await Self.graphql(Self.deviceEndpoint, authorization: Self.apiKey, query: Self.registerDeviceQuery, variables: [
            "registerDevice": [
                "applicationRuntime": "safari", "deviceFamily": "browser", "deviceLanguage": "en", "deviceProfile": "macosx",
                "attributes": ["browserName": "safari", "browserVersion": "26.0", "manufacturer": "apple", "model": NSNull(),
                               "operatingSystem": "macintosh", "operatingSystemVersion": "10.15.7", "osDeviceIds": []],
            ],
        ])
        let login = try await Self.graphql(Self.queryEndpoint, authorization: "Bearer \(device.token.access)", operation: "login",
                                           query: Self.loginQuery, variables: ["input": ["email": email, "password": password]])
        let account = (login.data["login"] as? [String: Any])?["account"] as? [String: Any]
        let profiles = (account?["profiles"] as? [[String: Any]] ?? []).compactMap { json -> SignInProfile? in
            guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
            let attributes = json["attributes"] as? [String: Any]
            return SignInProfile(id: id, name: name,
                                 isPinProtected: (attributes?["parentalControls"] as? [String: Any])?["isPinProtected"] as? Bool ?? false,
                                 isKids: attributes?["kidsModeEnabled"] as? Bool ?? false)
        }
        guard !profiles.isEmpty else { throw DisneyError.badResponse("profiles") }
        accountToken = login.token.access
        credentials = Credentials(email: email, password: password)
        return profiles
    }

    /// Picks the profile and stores the session token that comes back.
    func pick(_ profile: SignInProfile, pin: String?) async throws {
        guard let accountToken else { throw DisneyError.badResponse("account") }
        var input: [String: Any] = ["profileId": profile.id]
        if let pin { input["entryPin"] = pin }
        let result = try await Self.graphql(Self.queryEndpoint, authorization: "Bearer \(accountToken)", operation: "switchProfile",
                                            query: Self.switchProfileQuery, variables: ["input": input])
        try Task.checkCancellation()
        if !automatic, var credentials {
            credentials.profileID = profile.id
            try Self.save(credentials)
        }
        Session.store(token: result.token.access, refreshToken: result.token.refresh, expiresIn: result.token.expiresIn)
        credentials = nil
        if !automatic { Self.attemptedRecovery = false }
    }

    /// Renews the stored session with its refresh token; false when there is none or the service refused.
    static func refresh() async -> Bool {
        guard let refreshToken = Session.refreshToken,
              let result = try? await graphql(deviceEndpoint, authorization: apiKey, operation: "refreshToken", query: refreshQuery,
                                              variables: ["input": ["refreshToken": refreshToken]]),
              Session.isAccount(result.token.access) else { return false }
        Session.store(token: result.token.access, refreshToken: result.token.refresh, expiresIn: result.token.expiresIn)
        return true
    }

    static func signOut() {
        stopRecovery()
        SecItemDelete(credentialKey as CFDictionary)
        Session.clear()
    }

    private struct Token {
        let access: String
        let refresh: String?
        let expiresIn: Double
    }

    /// Posts a GraphQL operation; returns its `data` and the token the SDK extension sends back with it.
    private static func graphql(_ url: URL, authorization: String, operation: String? = nil, query: String,
                                variables: [String: Any]) async throws -> (data: [String: Any], token: Token) {
        var body: [String: Any] = ["query": query, "variables": variables]
        if let operation { body["operationName"] = operation }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DisneyError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let error = (object["errors"] as? [[String: Any]])?.first {
            throw DisneyError.signIn((error["extensions"] as? [String: Any])?["code"] as? String ?? error["message"] as? String ?? "")
        }
        guard let token = ((object["extensions"] as? [String: Any])?["sdk"] as? [String: Any])?["token"] as? [String: Any],
              let access = token["accessToken"] as? String else { throw DisneyError.badResponse("token") }
        return (object["data"] as? [String: Any] ?? [:],
                Token(access: access, refresh: token["refreshToken"] as? String, expiresIn: token["expiresIn"] as? Double ?? 14400))
    }
}

struct SignInView: View {
    let onSignedIn: () -> Void

    var body: some View {
        CredentialSignInView(service: DisneyAuth(), onSignedIn: onSignedIn)
    }
}
