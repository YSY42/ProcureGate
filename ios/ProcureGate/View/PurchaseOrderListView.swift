//
//  PurchaseOrderListView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import SwiftUI

enum GroupingMode: String, CaseIterable, Identifiable {
    case byProgress = "By Progress"
    case byRole = "By Role"
    var id: String { rawValue }
}

struct PurchaseOrderListView: View {
    let purchaseOrders: [PurchaseOrder]
    @Binding var selection: PurchaseOrder.ID?
    let isLoading: Bool
    @Binding var errorMessage: String?
    var onReload: () async -> Void

    @State private var showingCreateSheet = false
    @State private var groupingMode: GroupingMode = .byProgress
    @State private var expandedSections: Set<String> = ["Needs Your Action", "Blocked", "In Progress"]

    private var currentUserRole: String? {
        APIClient.shared.currentUser?.role
    }

    // Only management-facing roles get to see the cross-role distribution view.
    // A requester only ever needs to track their own POs — the role-lane view
    // is a supervisory concept, not something they have a use for.
    private var canViewByRole: Bool {
        currentUserRole == "procurement_lead" || currentUserRole == "department_approver"
    }

    // MARK: - Grouping by progress
    private var actionRequired: [PurchaseOrder] {
        purchaseOrders.filter { po in
            po.status == "submitted"
                && po.approvalSteps.contains { $0.status == "pending" && $0.requiredRole == currentUserRole }
        }
    }
    private var blocked: [PurchaseOrder] {
        purchaseOrders.filter { po in
            po.status == "submitted" && po.approvalControlStatus == "blocked"
        }
    }
    private var inProgress: [PurchaseOrder] {
        purchaseOrders.filter { po in
            po.status == "submitted"
                && po.approvalControlStatus != "blocked"
                && !po.approvalSteps.contains { $0.status == "pending" && $0.requiredRole == currentUserRole }
        }
    }
    private var completedNormal: [PurchaseOrder] {
        purchaseOrders.filter { ($0.status == "approved" || $0.status == "rejected") && !$0.approvedWithException }
    }
    private var completedWithException: [PurchaseOrder] {
        purchaseOrders.filter { ($0.status == "approved" || $0.status == "rejected") && $0.approvedWithException }
    }

    // MARK: - Grouping by role
    private var byRoleGroups: [(role: String, items: [PurchaseOrder])] {
        let roles = ["requester", "department_approver", "procurement_lead"]
        var buckets: [String: [PurchaseOrder]] = [:]
        var noPendingStep: [PurchaseOrder] = []

        for po in purchaseOrders {
            if po.status == "draft" {
                buckets["requester", default: []].append(po)
            } else if let step = po.approvalSteps.first(where: { $0.status == "pending" }) {
                buckets[step.requiredRole, default: []].append(po)
            } else {
                noPendingStep.append(po)
            }
        }

        var result = roles.compactMap { role -> (String, [PurchaseOrder])? in
            guard let items = buckets[role], !items.isEmpty else { return nil }
            return (role, items)
        }
        if !noPendingStep.isEmpty {
            result.append(("No Pending Step", noPendingStep))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if canViewByRole {
                Picker("Group by", selection: $groupingMode) {
                    ForEach(GroupingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(8)
            }

            List(selection: $selection) {
                if !canViewByRole || groupingMode == .byProgress {
                    group("Needs Your Action", items: actionRequired, systemImage: "exclamationmark.circle.fill", tint: .red)
                    group("Blocked", items: blocked, systemImage: "hand.raised.fill", tint: .orange)
                    group("In Progress", items: inProgress, systemImage: "clock.fill", tint: .yellow)
                    group("Completed — Normal", items: completedNormal, systemImage: "checkmark.circle.fill", tint: .secondary)
                    group("Completed — With Exception", items: completedWithException, systemImage: "exclamationmark.shield.fill", tint: .purple)
                } else {
                    ForEach(byRoleGroups, id: \.role) { entry in
                        group(
                            roleLabel(entry.role),
                            items: entry.items,
                            systemImage: roleIcon(entry.role),
                            tint: roleColor(entry.role)
                        )
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Purchase Orders")
        .toolbar {
            ToolbarItem {
                Button("New PO") {
                    showingCreateSheet = true
                }
            }
            ToolbarItem {
                Button("Refresh") {
                    Task { await onReload() }
                }
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreatePurchaseOrderView {
                Task { await onReload() }
            }
        }
        .overlay {
            if isLoading { ProgressView() }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "requester": return "With Requester (Draft)"
        case "department_approver": return "With Department Approver"
        case "procurement_lead": return "With Procurement Lead"
        default: return role.capitalized
        }
    }
    private func roleIcon(_ role: String) -> String {
        switch role {
        case "requester": return "pencil.circle.fill"
        case "department_approver": return "person.fill.checkmark"
        case "procurement_lead": return "person.badge.shield.checkmark.fill"
        default: return "circle.fill"
        }
    }
    private func roleColor(_ role: String) -> Color {
        switch role {
        case "requester": return .gray
        case "department_approver": return .blue
        case "procurement_lead": return .purple
        default: return .secondary
        }
    }

    @ViewBuilder
    private func group(
        _ title: String,
        items: [PurchaseOrder],
        systemImage: String,
        tint: Color
    ) -> some View {
        if !items.isEmpty {
            Section {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedSections.contains(title) },
                    set: { isExpanding in
                        if isExpanding {
                            expandedSections.insert(title)
                        } else {
                            expandedSections.remove(title)
                        }
                    }
                )) {
                    ForEach(items) { po in
                        row(for: po).tag(po.id)
                    }
                } label: {
                    Label("\(title) (\(items.count))", systemImage: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(tint)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for po: PurchaseOrder) -> some View {
        let risk = RiskStatus(rawValue: po.approvalControlStatus)

        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(risk.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("PO #\(po.id) — \(po.description)")
                    .font(.headline)
                HStack(spacing: 6) {
                    Text("\(po.amount) \(po.currency)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(risk.label + " risk")
                        .font(.caption)
                        .foregroundColor(risk.color)
                }
            }

            Spacer()
            approvalProgressIndicator(for: po)
        }
        .padding(.vertical, 6)
        .background(risk.color.opacity(0.06))
    }

    @ViewBuilder
    private func approvalProgressIndicator(for po: PurchaseOrder) -> some View {
        switch po.status {
        case "approved":
            if po.approvedWithException {
                Label("Approved (Exception)", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.purple)
            } else {
                Label("Approved", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.green)
            }
        case "rejected":
            Label("Rejected", systemImage: "xmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundColor(.red)
        case "submitted":
            if po.approvalSteps.contains(where: { $0.status == "pending" && $0.requiredRole == currentUserRole }) {
                Label("Awaiting You", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.red)
            } else if let step = po.approvalSteps.first(where: { $0.status == "pending" }) {
                Label("Awaiting \(step.requiredRole)", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Label("Blocked", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.orange)
            }
        default:
            Label("Draft", systemImage: "doc.text")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
