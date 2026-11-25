import Foundation
import SmartTubeIOSCore

extension AuthService {

    /// Consecutive transient answers (server errors, rate limits) tolerated before sign-in fails.
    /// At the 5-second poll interval this is about a minute of Google being unwell.
    static let maxConsecutiveTransientFailures = 12

    // MARK: - Device Code request

    struct DeviceCodeResponse {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int
    }

    func requestDeviceCode(creds: YouTubeClientCredentials) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: Self.deviceCodeURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "scope": scope,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.deviceCodeRequestFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceCode = json["device_code"] as? String,
            let userCode = json["user_code"] as? String,
            let verURL = json["verification_url"] as? String,
            let expiresIn = json["expires_in"] as? Int
        else { throw AuthError.deviceCodeRequestFailed }

        return DeviceCodeResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verURL,
            expiresIn: expiresIn,
            interval: json["interval"] as? Int ?? 5
        )
    }

    // MARK: - Polling

    func pollForToken(
        deviceCode: String,
        interval: TimeInterval,
        creds: YouTubeClientCredentials,
        pollImmediately: Bool = false
    ) async {
        authLog.notice("Starting poll loop (interval \(Int(interval))s, immediate=\(pollImmediately))")
        var skipInitialSleep = pollImmediately
        var transientFailures = 0
        while !Task.isCancelled {
            if skipInitialSleep {
                skipInitialSleep = false
            } else {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            do {
                try await exchangeDeviceCode(deviceCode: deviceCode, creds: creds)
                transientFailures = 0
                authLog.notice("✅ Token exchanged — fetching user info")
                try await fetchUserInfo()
                authLog.notice("✅ Signed in as \(self.accountName ?? "unknown")")
                // Fetch YouTube.com SAPISID cookie for WEB_CREATOR SAPISIDHASH auth.
                // Best-effort: runs in background, failure doesn't block sign-in.
                Task { await self.fetchYouTubeWebCookies() }
                pendingActivation = nil
                pollTask = nil
                return
            } catch AuthError.authorizationPending {
                authLog.debug("Polling… (authorization_pending)")
                continue
            } catch AuthError.transientTokenFailure {
                transientFailures += 1
                if transientFailures >= Self.maxConsecutiveTransientFailures {
                    authLog.error("Giving up after \(transientFailures) transient token failures in a row")
                    self.error = AuthError.transientTokenFailure
                    pendingActivation = nil
                    pollTask = nil
                    return
                }
                continue
            } catch AuthError.slowDown {
                authLog.notice("slow_down received — waiting extra 5s")
                try? await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
                continue
            } catch let urlError as URLError {
                authLog.notice("Network error during poll (transient, retrying): \(urlError.localizedDescription)")
                continue
            } catch {
                authLog.error("❌ Poll error: \(String(describing: error))")
                if isSignedIn { return }
                self.error = error
                pendingActivation = nil
                pollTask = nil
                return
            }
        }
        authLog.notice("Poll loop cancelled")
    }

    func exchangeDeviceCode(deviceCode: String, creds: YouTubeClientCredentials) async throws {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "code": deviceCode,
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "grant_type": "http://oauth.net/grant_type/device/1.0",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch DeviceTokenResponse.classify(statusCode: statusCode, data: data) {
        case .authorizationPending: throw AuthError.authorizationPending
        case .slowDown: throw AuthError.slowDown
        case .accessDenied: throw AuthError.cancelled
        case .expired: throw AuthError.deviceCodeExpired
        case .transient(let reason):
            authLog.notice("Token poll got a transient answer (\(reason)); will retry")
            throw AuthError.transientTokenFailure
        case .permanent(let reason):
            // The OAuth error code or HTTP status only: never the body, which can hold tokens.
            authLog.error("Token exchange failed permanently (\(reason))")
            throw AuthError.tokenExchangeFailed
        case .tokens(let tokens):
            accessToken = tokens.accessToken
            if let newRefresh = tokens.refreshToken { refreshToken = newRefresh }
            if let exp = tokens.expiresIn { tokenExpiry = Date().addingTimeInterval(exp - 60) }
        }
        isSignedIn = accessToken != nil
        saveToKeychain()
        scheduleProactiveRefresh()
    }
}
