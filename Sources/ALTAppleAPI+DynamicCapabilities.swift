//
//  ALTAppleAPI+DynamicCapabilities.swift
//  AltSign
//
//  Discovers modern Developer Portal capabilities dynamically and enables them
//  without hard-coding Apple's capability identifier.
//

import Foundation
import SwiftBridge

public extension ALTAppleAPI {
    /// Enables the modern Developer Portal capability whose provisioning-profile
    /// entitlement key matches `entitlement` for `bundleIdentifier`.
    ///
    /// This uses Apple's v1 JSON:API, the same transport used by current Xcode.
    /// Existing enabled capabilities are preserved when the Bundle ID is patched.
    @discardableResult
    func enableDynamicCapability(
        for entitlement: ALTEntitlement,
        bundleIdentifier: String,
        team: ALTTeam,
        session apiSession: ALTAppleAPISession
    ) async throws -> String {
        let capabilityResponse = try await self.dynamicCapabilitiesRequest(
            path: "capabilities",
            logicalMethod: "GET",
            body: [
                "teamId": team.identifier,
                "urlEncodedQueryParams": "filter[platform]=IOS"
            ],
            session: apiSession
        )

        guard let capabilityItems = capabilityResponse["data"] as? [[String: Any]] else {
            throw self.dynamicCapabilityError("Apple returned no capability list for team \(team.identifier).")
        }

        let entitlementKey = entitlement.rawValue
        let matchingCapability = capabilityItems.first { item in
            guard
                let attributes = item["attributes"] as? [String: Any],
                let entitlements = attributes["entitlements"] as? [[String: Any]]
            else {
                return false
            }

            let hasProfileKey = entitlements.contains { entry in
                (entry["profileKey"] as? String) == entitlementKey
            }
            guard hasProfileKey else { return false }

            // If Apple supplied SDK/distribution metadata, require iOS + Development.
            if let sdks = attributes["supportedSDKs"] as? [[String: Any]], !sdks.isEmpty {
                let supportsIOS = sdks.contains {
                    ($0["name"] as? String) == "IOS" || ($0["displayValue"] as? String) == "iOS"
                }
                guard supportsIOS else { return false }
            }

            if let distributionTypes = attributes["distributionTypes"] as? [[String: Any]], !distributionTypes.isEmpty {
                let supportsDevelopment = distributionTypes.contains {
                    ($0["name"] as? String) == "DEVELOPMENT" || ($0["displayValue"] as? String) == "Development"
                }
                guard supportsDevelopment else { return false }
            }

            return true
        }

        guard let matchingCapability,
              let capabilityID = matchingCapability["id"] as? String else {
            throw self.dynamicCapabilityError(
                "Apple did not advertise a Development/iOS capability for \(entitlementKey) to team \(team.identifier)."
            )
        }

        let capabilityName = ((matchingCapability["attributes"] as? [String: Any])?["name"] as? String) ?? capabilityID
        debugLog("[AltSign] Dynamic capability discovery matched \(entitlementKey) -> \(capabilityID) (\(capabilityName))")

        let bundleIDsResponse = try await self.dynamicCapabilitiesRequest(
            path: "bundleIds",
            logicalMethod: "GET",
            body: [
                "teamId": team.identifier,
                "urlEncodedQueryParams": "limit=1000"
            ],
            session: apiSession
        )

        guard let bundleItems = bundleIDsResponse["data"] as? [[String: Any]],
              let bundleItem = bundleItems.first(where: { item in
                  guard let attributes = item["attributes"] as? [String: Any] else { return false }
                  return (attributes["identifier"] as? String)?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
              }),
              let bundleResourceID = bundleItem["id"] as? String,
              let bundleAttributes = bundleItem["attributes"] as? [String: Any]
        else {
            throw self.dynamicCapabilityError(
                "Apple's v1 Developer Portal API could not find Bundle ID \(bundleIdentifier)."
            )
        }

        let existingResponse = try await self.dynamicCapabilitiesRequest(
            path: "bundleIds/\(bundleResourceID)/bundleIdCapabilities",
            logicalMethod: "GET",
            body: [
                "teamId": team.identifier,
                "urlEncodedQueryParams": "limit=1000"
            ],
            session: apiSession
        )

        var enabledCapabilityIDs = Set<String>()
        if let resources = existingResponse["data"] as? [[String: Any]] {
            for resource in resources {
                guard
                    let relationships = resource["relationships"] as? [String: Any],
                    let capability = relationships["capability"] as? [String: Any],
                    let data = capability["data"] as? [String: Any],
                    let id = data["id"] as? String
                else {
                    continue
                }
                enabledCapabilityIDs.insert(id)
            }
        }

        if enabledCapabilityIDs.contains(capabilityID) {
            debugLog("[AltSign] Dynamic capability \(capabilityID) is already enabled for \(bundleIdentifier).")
            return capabilityID
        }

        enabledCapabilityIDs.insert(capabilityID)

        guard let identifier = bundleAttributes["identifier"] as? String else {
            throw self.dynamicCapabilityError("Apple's Bundle ID response is missing identifier for \(bundleIdentifier).")
        }

        let seedID = (bundleAttributes["seedId"] as? String) ?? team.identifier
        let name = (bundleAttributes["name"] as? String) ?? bundleIdentifier
        let wildcard = (bundleAttributes["wildcard"] as? Bool) ?? false

        let capabilityResources: [[String: Any]] = enabledCapabilityIDs.sorted().map { id in
            [
                "type": "bundleIdCapabilities",
                "attributes": [
                    "enabled": true,
                    "settings": []
                ],
                "relationships": [
                    "capability": [
                        "data": [
                            "type": "capabilities",
                            "id": id
                        ]
                    ]
                ]
            ]
        }

        let patchBody: [String: Any] = [
            "data": [
                "type": "bundleIds",
                "id": bundleResourceID,
                "attributes": [
                    "identifier": identifier,
                    "seedId": seedID,
                    "teamId": team.identifier,
                    "name": name,
                    "wildcard": wildcard
                ],
                "relationships": [
                    "bundleIdCapabilities": [
                        "data": capabilityResources
                    ]
                ]
            ]
        ]

        _ = try await self.dynamicCapabilitiesRequest(
            path: "bundleIds/\(bundleResourceID)",
            logicalMethod: "PATCH",
            body: patchBody,
            session: apiSession
        )

        debugLog("[AltSign] Enabled dynamic capability \(capabilityID) for \(bundleIdentifier), preserving \(enabledCapabilityIDs.count - 1) existing capabilities.")
        return capabilityID
    }
}

private extension ALTAppleAPI {
    func dynamicCapabilitiesRequest(
        path: String,
        logicalMethod: String,
        body: [String: Any],
        session apiSession: ALTAppleAPISession
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: self.servicesBaseURL) else {
            throw self.dynamicCapabilityError("Could not construct Apple Developer Portal URL for \(path).")
        }

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw self.dynamicCapabilityError("Could not encode Apple Developer Portal request: \(error.localizedDescription)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = logicalMethod == "GET" ? "POST" : logicalMethod
        request.httpBody = bodyData
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
        request.setValue(apiSession.xcodeVersion, forHTTPHeaderField: "X-Xcode-Version")
        request.setValue(apiSession.dsid, forHTTPHeaderField: "X-Apple-I-Identity-Id")
        request.setValue(apiSession.authToken, forHTTPHeaderField: "X-Apple-GS-Token")

        if logicalMethod == "GET" {
            request.setValue("GET", forHTTPHeaderField: "X-HTTP-Method-Override")
        }

        let anisette = apiSession.anisetteData
        request.setValue(anisette.machineID, forHTTPHeaderField: "X-Apple-I-MD-M")
        request.setValue(anisette.oneTimePassword, forHTTPHeaderField: "X-Apple-I-MD")
        request.setValue(anisette.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue("\(anisette.routingInfo)", forHTTPHeaderField: "X-Apple-I-MD-RINFO")
        request.setValue(anisette.deviceUniqueIdentifier, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(anisette.deviceDescription, forHTTPHeaderField: "X-MMe-Client-Info")
        request.setValue(self.dateFormatter.string(from: anisette.date), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(anisette.locale.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(anisette.timeZone.abbreviation(for: anisette.date) ?? "", forHTTPHeaderField: "X-Apple-I-TimeZone")

        verboseLog("[AltSign] Dynamic capability request \(logicalMethod) \(url.absoluteString)")

        return try await withCheckedThrowingContinuation { continuation in
            self.session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: self.dynamicCapabilityError("Apple returned an empty response for \(path)."))
                    return
                }

                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard let object = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = object as? [String: Any] else {
                    let raw = String(data: data, encoding: .utf8) ?? "<binary response>"
                    continuation.resume(throwing: self.dynamicCapabilityError("Apple returned an invalid response for \(path): \(raw)"))
                    return
                }

                if let errors = dictionary["errors"] as? [[String: Any]], let first = errors.first {
                    let message = (first["detail"] as? String)
                        ?? (first["title"] as? String)
                        ?? "Apple rejected the capability request."
                    let resultCode = (first["resultCode"] as? NSNumber)?.intValue ?? httpStatus
                    continuation.resume(throwing: NSError(
                        domain: ALTUnderlyingAppleAPIErrorDomain,
                        code: resultCode,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                    return
                }

                guard (200..<300).contains(httpStatus) else {
                    continuation.resume(throwing: self.dynamicCapabilityError("Apple Developer Portal returned HTTP \(httpStatus) for \(path)."))
                    return
                }

                continuation.resume(returning: dictionary)
            }.resume()
        }
    }

    func dynamicCapabilityError(_ message: String) -> NSError {
        NSError(
            domain: ALTAppleAPIErrorDomain,
            code: ALTAppleAPIError.invalidParameters.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
