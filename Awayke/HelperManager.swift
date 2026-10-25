//
//  HelperManager.swift
//  Awayke
//

import Foundation
import ServiceManagement
import AppKit

enum HelperState: Equatable {
    case notRegistered
    case awaitingApproval
    case enabled
    case notFound
}

enum HelperError: LocalizedError {
    case helperUnavailable
    case connectionFailed(String)
    case remoteError(Error)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "Awayke's privileged helper isn't approved yet."
        case .connectionFailed(let detail):
            return "Couldn't connect to Awayke's helper: \(detail)"
        case .remoteError(let underlying):
            return underlying.localizedDescription
        }
    }
}

final class HelperManager {

    static let shared = HelperManager()

    private static let plistName = "daemonphantom.Awayke.Helper.plist"
    private static let machServiceName = "daemonphantom.Awayke.Helper"

    private let service: SMAppService
    private var connection: NSXPCConnection?

    private init() {
        self.service = SMAppService.daemon(plistName: Self.plistName)
    }

    var state: HelperState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .awaitingApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    var isUsable: Bool { state == .enabled }

    /// Idempotent. Calling on a fresh install triggers the OS approval flow
    /// and surfaces the helper in System Settings → Login Items.
    func register() {
        do {
            try service.register()
        } catch {
            NSLog("Awayke: SMAppService.register() failed: \((error as NSError).localizedDescription)")
        }
    }

    func revealInSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func unregister() {
        do {
            try service.unregister()
        } catch {
            NSLog("Awayke: SMAppService.unregister() failed: \((error as NSError).localizedDescription)")
        }
    }

    func setSleepDisabled(_ disable: Bool) async throws {
        guard isUsable else { throw HelperError.helperUnavailable }
        let conn = connection ?? makeConnection()
        connection = conn
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: HelperError.connectionFailed(error.localizedDescription))
            }) as? AwaykeHelperProtocol else {
                continuation.resume(throwing: HelperError.connectionFailed("Invalid helper proxy."))
                return
            }
            proxy.setSleepDisabled(disable) { remoteError in
                if let remoteError {
                    continuation.resume(throwing: HelperError.remoteError(remoteError))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: AwaykeHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        conn.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        conn.resume()
        return conn
    }
}
