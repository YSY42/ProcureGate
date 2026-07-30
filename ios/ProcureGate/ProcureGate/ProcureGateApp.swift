//
//  ProcureGateApp.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif

@main
struct ProcureGateApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 750)
    }
}

// MARK: - PO status change notifications

/// Polls the buyer's own purchase orders while the app is running and posts
/// a local notification + Dock badge count when a status changes.
///
/// This app has no push infrastructure (no APNs registration, no server-side
/// push) — polling while the app is open is the pragmatic in-app substitute.
/// It catches "my PO got approved/rejected/blocked while I was working on
/// something else in this window," not true background/closed-app delivery.
@MainActor
final class POStatusNotifier: ObservableObject {
    static let shared = POStatusNotifier()

    @Published private(set) var unseenChangeCount = 0

    private var lastKnownStates: [Int: String] = [:]
    private var pollTask: Task<Void, Never>?
    private let defaultsKey = "POStatusNotifier.lastKnownStates"

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] {
            lastKnownStates = Dictionary(
                uniqueKeysWithValues: saved.compactMap { key, value in Int(key).map { ($0, value) } }
            )
        }
    }

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func startPolling(intervalSeconds: UInt64 = 30) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await checkForChanges()
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Call when the buyer opens their PO list — resets the Dock badge, the
    /// same way opening Mail clears its unread count.
    func markAllSeen() {
        unseenChangeCount = 0
        updateDockBadge()
    }

    private func checkForChanges() async {
        guard APIClient.shared.currentUser?.role == "requester" else { return }
        guard let pos = try? await APIClient.shared.fetchPurchaseOrders() else { return }

        var changedCount = 0
        for po in pos {
            let currentState = "\(po.status)|\(po.approvalControlStatus ?? "")"
            if let previousState = lastKnownStates[po.id], previousState != currentState {
                changedCount += 1
                postNotification(for: po)
            }
            lastKnownStates[po.id] = currentState
        }
        persistState()

        if changedCount > 0 {
            unseenChangeCount += changedCount
            updateDockBadge()
        }
    }

    private func postNotification(for po: PurchaseOrder) {
        let content = UNMutableNotificationContent()
        content.title = "PO #\(po.id) updated"
        content.body = "\(po.description) — now \(po.status.capitalized)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "po-\(po.id)-\(po.status)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func updateDockBadge() {
        #if os(macOS)
        NSApplication.shared.dockTile.badgeLabel = unseenChangeCount > 0 ? "\(unseenChangeCount)" : nil
        #endif
    }

    private func persistState() {
        let stringKeyed = Dictionary(uniqueKeysWithValues: lastKnownStates.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(stringKeyed, forKey: defaultsKey)
    }
}
