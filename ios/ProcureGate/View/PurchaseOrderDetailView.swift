//
//  PurchaseOrderDetailView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import SwiftUI

enum PendingApprovalAction: Equatable {
    case reject, escalate
}

struct PurchaseOrderDetailView: View {
    let po: PurchaseOrder
    var onActionCompleted: (() -> Void)? = nil
    @State private var isProcessing = false
    @State private var actionError: String?
    @State private var updatedPO: PurchaseOrder?
    @State private var showingExceptionSheet = false
    @State private var showingDuplicateSheet = false
    @State private var avgApprovalTimeByTier: [String: Double?] = [:]
    @State private var requesterSupplierHistory: APIClient.RequesterSupplierHistory?
    @State private var pendingAction: PendingApprovalAction?
    @State private var noteText = ""

    private var canCreatePO: Bool {
        let role = APIClient.shared.currentUser?.role
        return role == "requester" || role == "procurement_lead"
    }

    // What an approver can't currently see anywhere else: has this same
    // requester been blocked against this same supplier before, and why —
    // surfaced at decision time instead of only discoverable later from
    // procurement_lead's aggregate drift signals.
    private var historyWarning: String? {
        guard let requesterSupplierHistory, requesterSupplierHistory.blockedCount > 0 else { return nil }
        let counts = Dictionary(grouping: requesterSupplierHistory.details, by: { $0.actionType })
            .mapValues { $0.count }
        let reasons = counts
            .sorted { $0.value > $1.value }
            .map { "\(triggerReasonLabel($0.key)) (\($0.value)x)" }
            .joined(separator: ", ")
        return "\(po.requesterEmail) has had \(requesterSupplierHistory.blockedCount) order"
            + "\(requesterSupplierHistory.blockedCount == 1 ? "" : "s") blocked for this supplier before — \(reasons)"
    }

    private func triggerReasonLabel(_ actionType: String) -> String {
        switch actionType {
        case "risk_trigger_compliance_floor": return "compliance floor"
        case "risk_trigger_stale": return "stale assessment"
        case "risk_trigger_incomplete_or_unassessed": return "incomplete assessment"
        default: return actionType.replacingOccurrences(of: "_", with: " ")
        }
    }

    // Same benchmark procurement_lead already sees system-wide (avg days to
    // decide, grouped by supplier risk tier) — surfaced here for the buyer
    // against the specific tier of *this* order, so "how long will this
    // take" has an answer instead of silence while it's pending.
    private var waitTimeEstimate: String? {
        guard po.status == "submitted", let tier = po.supplierRiskTier?.lowercased() else { return nil }
        guard let days = avgApprovalTimeByTier[tier].flatMap({ $0 }) else { return nil }
        return "Orders at \(tier.capitalized) risk have historically taken about "
            + "\(String(format: "%.1f", days)) day\(days == 1 ? "" : "s") to decide."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard

                riskBreakdownCard

                if let currentStep = po.approvalSteps.first(where: { $0.status == "pending" }),
                   currentStep.requiredRole == APIClient.shared.currentUser?.role {
                    actionRequiredCard
                }

                if po.approvalControlStatus == "blocked" && po.status != "approved" && po.status != "rejected" {
                    blockedCard
                }

                approvalStepsCard
            }
            .padding(24)
        }
        .navigationTitle("PO #\(po.id)")
        .task {
            await loadWaitTimeEstimateIfApplicable()
            await loadHistoryIfApplicable()
        }
        .sheet(isPresented: $showingExceptionSheet) {
            CreateExceptionRequestView(poId: po.id) {
                onActionCompleted?()
            }
        }
        .sheet(isPresented: $showingDuplicateSheet) {
            CreatePurchaseOrderView(prefillSupplierId: po.supplierId, prefillDescription: po.description) {
                onActionCompleted?()
            }
        }
    }

    private func loadWaitTimeEstimateIfApplicable() async {
        guard po.status == "submitted", APIClient.shared.currentUser?.role == "requester" else { return }
        if let dashboard = try? await APIClient.shared.fetchRequesterDashboard() {
            avgApprovalTimeByTier = dashboard.avgApprovalTimeByTier
        }
    }

    private func loadHistoryIfApplicable() async {
        guard po.status == "submitted",
              let role = APIClient.shared.currentUser?.role,
              role == "department_approver" || role == "procurement_lead" else { return }
        requesterSupplierHistory = try? await APIClient.shared.fetchRequesterSupplierHistory(poId: po.id)
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text("PO #\(po.id)")
                    .font(.largeTitle.bold())
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(po.status.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.15))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                    statusBadge
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("DESCRIPTION")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary)
                Text(po.description)
                    .font(.title3)
            }

            Divider()

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SUPPLIER")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                    Text(po.supplierName)
                        .font(.subheadline.weight(.semibold))
                    Text("Supplier #\(po.supplierId)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("REQUESTED BY")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                    Text(po.requesterEmail)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AMOUNT")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                    Text("\(po.amount) \(po.currency)")
                        .font(.title2.weight(.semibold))
                }
                if po.approvedWithException {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EXCEPTION")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.secondary)
                        Label("Approved with Exception", systemImage: "exclamationmark.shield.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.purple)
                    }
                }
                Spacer()
            }

            Divider()

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CREATED")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                    Text(po.createdAt.asFormattedDateTime)
                        .font(.caption)
                }
                if let submittedAt = po.submittedAt {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SUBMITTED")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.secondary)
                        Text(submittedAt.asFormattedDateTime)
                            .font(.caption)
                    }
                }
                if let decidedAt = po.decidedAt {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DECIDED")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.secondary)
                        Text(decidedAt.asFormattedDateTime)
                            .font(.caption)
                    }
                }
                Spacer()
            }

            if let waitTimeEstimate {
                Divider()
                Label(waitTimeEstimate, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if canCreatePO {
                Divider()
                Button {
                    showingDuplicateSheet = true
                } label: {
                    Label("Create Similar Order", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(20)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(14)
    }

    // MARK: - Risk breakdown

    // The aggregate tier ("Conditional") is worst-of-three — this shows
    // *which* layer drove it, so a decision-maker can tell "country risk is
    // structural, nothing to ask about" apart from "delivery performance
    // just got worse, might be worth a question."
    private var riskBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why This Risk Tier")
                .font(.title3.bold())

            HStack(spacing: 12) {
                riskLayerTile("Country / Category", tier: po.supplierInherentRiskTier)
                riskLayerTile("Delivery / Defects", tier: po.supplierPerformanceRiskTier)
                riskLayerTile("ESG / Sanctions", tier: po.supplierComplianceRiskTier)
            }

            Text("The overall tier is the worst of these three layers.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(14)
    }

    @ViewBuilder
    private func riskLayerTile(_ label: String, tier: String?) -> some View {
        let color = tierColor(tier)
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundColor(.secondary)
            Text(tier?.capitalized ?? "Unknown")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .cornerRadius(8)
    }

    private func tierColor(_ tier: String?) -> Color {
        switch tier {
        case "low": return .green
        case "medium": return .yellow
        case "high": return .red
        default: return .secondary
        }
    }

    // MARK: - Action required

    private var actionRequiredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your Action Required", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.title3.bold())
                .foregroundColor(.red)

            if let historyWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(historyWarning)
                        .font(.subheadline)
                }
                .foregroundColor(.orange)
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if let pendingAction {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pendingAction == .reject ? "Reason for rejecting (required)" : "What should procurement lead take a look at?")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    TextField(
                        pendingAction == .reject
                            ? "e.g. Pricing doesn't match the quote on file"
                            : "e.g. Borderline case, want a second opinion",
                        text: $noteText,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(10)
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(8)

                    HStack {
                        Button("Cancel") {
                            self.pendingAction = nil
                            noteText = ""
                        }
                        Spacer()
                        Button(pendingAction == .reject ? "Confirm Reject" : "Send to Lead") {
                            Task { await confirmPendingAction() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(pendingAction == .reject ? .red : .orange)
                        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Button {
                        Task { await performTransition(action: "approve") }
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button {
                        pendingAction = .reject
                        noteText = ""
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button {
                        pendingAction = .escalate
                        noteText = ""
                    } label: {
                        Label("Ask Lead", systemImage: "arrow.up.forward.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }

            if isProcessing {
                ProgressView()
            }
            if let actionError {
                Text(actionError)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding(20)
        .background(Color.red.opacity(0.08))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Blocked

    private var blockedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Blocked: No Pending Approval Step", systemImage: "hand.raised.fill")
                .font(.title3.bold())
                .foregroundColor(.orange)
            Text("This PO cannot proceed through normal approval. Submit an exception request with justification to route it to an independent procurement lead for review.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Request Exception") {
                showingExceptionSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(20)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Approval steps timeline

    private var approvalStepsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Approval Steps")
                .font(.title3.bold())

            if po.approvalSteps.isEmpty {
                Text("No approval steps recorded.")
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(po.approvalSteps.enumerated()), id: \.element.id) { index, step in
                        stepRow(step, isLast: index == po.approvalSteps.count - 1)
                    }
                }
            }
        }
        .padding(20)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(14)
    }

    @ViewBuilder
    private func stepRow(_ step: ApprovalStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(stepColor(step).opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: stepIcon(step))
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(stepColor(step))
                }
                if !isLast {
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 2)
                        .frame(minHeight: 24)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Step \(step.stepNumber) · \(step.requiredRole.replacingOccurrences(of: "_", with: " ").capitalized)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(step.status.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(stepColor(step).opacity(0.15))
                        .foregroundColor(stepColor(step))
                        .clipShape(Capsule())
                }
                if let decidedById = step.decidedById {
                    Text("Decided by user #\(decidedById)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : 16)
        }
    }

    private func stepColor(_ step: ApprovalStep) -> Color {
        switch step.status {
        case "approved": return .green
        case "rejected": return .red
        case "pending": return .yellow
        default: return .secondary
        }
    }

    private func stepIcon(_ step: ApprovalStep) -> String {
        switch step.status {
        case "approved": return "checkmark"
        case "rejected": return "xmark"
        case "pending": return "clock.fill"
        default: return "circle"
        }
    }

    // MARK: - Status badge

    private var statusBadge: some View {
        let risk = RiskStatus(rawValue: po.approvalControlStatus)
        return Label(risk.label, systemImage: risk.icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(risk.color.opacity(0.15))
            .foregroundColor(risk.color)
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func performTransition(action: String, reason: String? = nil) async {
        isProcessing = true
        actionError = nil
        do {
            updatedPO = try await APIClient.shared.transitionPurchaseOrder(poId: po.id, action: action, reason: reason)
            onActionCompleted?()
        } catch {
            actionError = error.localizedDescription
        }
        isProcessing = false
    }

    private func confirmPendingAction() async {
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch pendingAction {
        case .reject:
            await performTransition(action: "reject", reason: note)
        case .escalate:
            await performEscalate(note: note)
        case nil:
            break
        }
        pendingAction = nil
        noteText = ""
    }

    private func performEscalate(note: String) async {
        isProcessing = true
        actionError = nil
        do {
            updatedPO = try await APIClient.shared.escalatePurchaseOrder(poId: po.id, note: note)
            onActionCompleted?()
        } catch {
            actionError = error.localizedDescription
        }
        isProcessing = false
    }
}
