//
//  PersonalDashboardView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 27/07/2026.
//

import SwiftUI

struct PersonalDashboardView: View {
    enum Scope {
        case requester
        case approver
    }
    
    let scope: Scope
    var onEnterWorkspace: () -> Void
    
    @State private var controlStatusBreakdown: [String: Int] = [:]
    @State private var triggerReasonBreakdown: [String: Int] = [:]
    @State private var pendingCount: Int = 0
    @State private var teamName: String? = nil
    @State private var selectedControlStatusForDrillDown: String? = nil
    @State private var selectedTriggerReasonForDrillDown: String? = nil
    @State private var purchaseOrdersForDrillDown: [PurchaseOrder] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var triggerReasonDetails: [APIClient.TriggerReasonDetail] = []
    
    private var title: String {
        scope == .requester ? "My Risk Picture" : "Team Risk Picture"
    }
    
    private var enterButtonLabel: String {
        scope == .requester ? "Enter My Purchase Orders" : "Enter Approval Queue"
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    breakdownSection
                    if !triggerReasonBreakdown.isEmpty {
                        triggerSection
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem {
                    Button(role: .destructive) {
                        APIClient.shared.logout()
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .task { await load() }
            .overlay {
                if isLoading { ProgressView() }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: Binding(
                            get: { selectedControlStatusForDrillDown.map { IdentifiableString(value: $0) } },
                            set: { selectedControlStatusForDrillDown = $0?.value }
                        )) { wrapped in
                            PurchaseOrderTierDrillDownView(
                                tier: wrapped.value,
                                orders: purchaseOrdersForDrillDown.filter { $0.approvalControlStatus == wrapped.value },
                                onActionCompleted: { Task { await load() } }
                            )
                        }
            .sheet(item: Binding(
                get: { selectedTriggerReasonForDrillDown.map { IdentifiableString(value: $0) } },
                set: { selectedTriggerReasonForDrillDown = $0?.value }
            )) { wrapped in
                TriggerReasonDetailListView(
                    reason: wrapped.value,
                    details: triggerReasonDetails.filter { $0.actionType == wrapped.value }
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onEnterWorkspace()
            } label: {
                Label(enterButtonLabel, systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
    
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if scope == .approver, let teamName {
                Text("Team: \(teamName)")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            if pendingCount > 0 {
                Button {
                    onEnterWorkspace()
                } label: {
                    HStack(spacing: 6) {
                        Text(scope == .requester
                             ? "\(pendingCount) of your orders are awaiting a decision."
                             : "\(pendingCount) orders are waiting on your team's queue.")
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.subheadline)
                    }
                    .font(.headline)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
        }
    }
    
    @ViewBuilder
    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scope == .requester ? "Where My Orders Landed" : "Where Team Orders Landed")
                .font(.title.bold())
            Text("How your submitted orders were routed by risk, using the same scale as the rest of the system.")
                .font(.body)
                .foregroundColor(.secondary)

            let tiers = ["allowed", "conditional", "escalated", "blocked"]
            let total = controlStatusBreakdown.values.reduce(0, +)

            if total == 0 {
                Text("No submitted orders yet.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    ForEach(tiers, id: \.self) { tier in
                        let count = controlStatusBreakdown[tier] ?? 0
                        let risk = RiskStatus(rawValue: tier)
                        Button {
                            if count > 0 {
                                selectedControlStatusForDrillDown = tier
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Text("\(count)")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                    .foregroundColor(count > 0 ? risk.color : .secondary.opacity(0.3))
                                Text(risk.label)
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(risk.color.opacity(count > 0 ? 0.1 : 0.03))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(count == 0)
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }
    
    @ViewBuilder
    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scope == .requester ? "Why Your Orders Got Blocked" : "Why Team Orders Got Blocked")
                .font(.title.bold())
            Text("If the same reason keeps showing up, it's worth checking with the supplier before submitting again.")
                .font(.body)
                .foregroundColor(.secondary)

            ForEach(triggerReasonBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { reason, count in
                Button {
                    selectedTriggerReasonForDrillDown = reason
                } label: {
                    HStack {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.headline)
                            .foregroundColor(.blue.opacity(0.6))
                        Text(reason.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.headline)
                        Spacer()
                        Text("\(count)")
                            .font(.headline.weight(.bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.06))
        .cornerRadius(10)
    }
    
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            switch scope {
            case .requester:
                let data = try await APIClient.shared.fetchRequesterDashboard()
                controlStatusBreakdown = data.myControlStatusBreakdown
                triggerReasonBreakdown = data.myTriggerReasonBreakdown
                pendingCount = data.myPurchaseOrders.filter { $0.status == "submitted" }.count
                purchaseOrdersForDrillDown = data.myPurchaseOrders
                triggerReasonDetails = data.myTriggerReasonDetails
            case .approver:
                let data = try await APIClient.shared.fetchApproverDashboard()
                controlStatusBreakdown = data.teamControlStatusBreakdown
                triggerReasonBreakdown = data.teamTriggerReasonBreakdown
                pendingCount = data.pendingApprovals.count
                teamName = data.team
                purchaseOrdersForDrillDown = data.teamPurchaseOrders
                triggerReasonDetails = data.teamTriggerReasonDetails
            }
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
