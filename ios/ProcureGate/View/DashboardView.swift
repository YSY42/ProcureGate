//
//  DashboardView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 26/07/2026.
//

import SwiftUI
import Charts

struct DashboardView: View {
    @State private var dashboard: APIClient.DashboardData?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedRiskTierForDrillDown: String? = nil
    @State private var selectedSupplierDrillDown: DriftDrillDownTarget? = nil
    @State private var selectedRequesterDrillDown: DriftDrillDownTarget? = nil
    @State private var selectedTriggerReasonDrillDown: String? = nil
    @State private var selectedApprovalTimeTierForDrillDown: String? = nil
    @State private var showingBlockedAttemptsDetail = false
    @State private var showingPendingExceptions = false
    @State private var showingRiskSettings = false
    @State private var flaggingSupplierId: Int? = nil
    @State private var flagNoteText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                if let dashboard {
                    VStack(alignment: .leading, spacing: 20) {
                        alertCardsSection(dashboard)
                        escalationsAndAgingSection(dashboard)
                        approvalTimeSection(dashboard)
                        exceptionDriftSection(dashboard)
                        HStack(alignment: .top, spacing: 20) {
                            riskDistributionSection(dashboard)
                            riskAmountExposureSection(dashboard)
                        }
                    }
                    .padding()
                } else if !isLoading {
                    ContentUnavailableView("No data", systemImage: "chart.bar")
                }
            }
            .navigationTitle("Governance Dashboard")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showingPendingExceptions = true
                    } label: {
                        Label("Pending Exceptions", systemImage: "checkmark.shield")
                    }
                    Button {
                        showingRiskSettings = true
                    } label: {
                        Label("Risk Settings", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
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
                get: { selectedRiskTierForDrillDown.map { IdentifiableString(value: $0) } },
                set: { selectedRiskTierForDrillDown = $0?.value }
            )) { wrapped in
                SupplierRiskTierListView(tier: wrapped.value)
            }
            .sheet(item: $selectedSupplierDrillDown) { target in
                ExceptionDetailListView(kind: .supplier(id: target.id, name: target.name))
            }
            .sheet(item: $selectedRequesterDrillDown) { target in
                ExceptionDetailListView(kind: .requester(id: target.id, email: target.name))
            }
            .sheet(item: Binding(
                get: { selectedTriggerReasonDrillDown.map { IdentifiableString(value: $0) } },
                set: { selectedTriggerReasonDrillDown = $0?.value }
            )) { wrapped in
                TriggerReasonDetailListView(
                    reason: wrapped.value,
                    details: (dashboard?.exceptionDriftSignals.triggerReasonDetails ?? [])
                        .filter { $0.actionType == wrapped.value }
                )
            }
            .sheet(isPresented: $showingBlockedAttemptsDetail) {
                BlockedAttemptsDetailView(
                    details: dashboard?.blockedCreationAttemptDetails ?? []
                )
            }
            .sheet(item: Binding(
                get: { selectedApprovalTimeTierForDrillDown.map { IdentifiableString(value: $0) } },
                set: { selectedApprovalTimeTierForDrillDown = $0?.value }
            )) { wrapped in
                ApprovalTimeDetailListView(tier: wrapped.value)
            }
            .sheet(isPresented: $showingPendingExceptions) {
                PendingExceptionsView()
            }
            .sheet(isPresented: $showingRiskSettings) {
                RiskSettingsView()
            }
        }
    }

    // MARK: - Section 1: Control-effectiveness alert cards (highest priority)

    @ViewBuilder
    private func alertCardsSection(_ d: APIClient.DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Control Effectiveness")
                .font(.title.bold())

            HStack(alignment: .top, spacing: 12) {
                Button {
                    if d.blockedCreationAttempts > 0 {
                        showingBlockedAttemptsDetail = true
                    }
                } label: {
                    alertCard(
                        title: "Bypass Attempts Stopped",
                        value: "\(d.blockedCreationAttempts)",
                        detail: d.blockedCreationAttempts > 0
                            ? "Tap to see which suppliers and who attempted."
                            : "Blocked-supplier PO attempts, rejected before scoring.",
                        icon: "hand.raised.fill",
                        tint: d.blockedCreationAttempts > 0 ? .green : .secondary
                    )
                }
                .buttonStyle(.plain)
                .disabled(d.blockedCreationAttempts == 0)

                alertCard(
                    title: "Orders Blocked on Unreliable Supplier Data",
                    value: "\(d.posAffectedByStaleOrUnassessed)",
                    detail: "Triggers automatically as assessments age out. Not manually triggerable in this demo.",
                    icon: "clock.badge.exclamationmark",
                    tint: .secondary
                )
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func alertCard(title: String, value: String, detail: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(tint)
                Spacer()
                Text(value)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
            }
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - Section 1b: Approver escalations & per-team pending backlog

    // Two gaps in one section: department_approver has no audit-trail
    // access, so "asked for a second look" notes would otherwise be
    // invisible to procurement_lead; and pending aging was system-wide only
    // — broken down by team here because approval-step authority is
    // role+team-matched (any department_approver on the requester's team),
    // not assigned to one named person, so team is the unit that can
    // actually go unstaffed/backlogged.
    @ViewBuilder
    private func escalationsAndAgingSection(_ d: APIClient.DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approver Escalations & Backlog")
                .font(.title.bold())

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Asked for a Second Look")
                        .font(.headline)
                    if d.escalatedApprovals.isEmpty {
                        Text("No approvals have been escalated.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(d.escalatedApprovals) { escalation in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("PO #\(escalation.poId)")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(escalation.at.asFormattedDateTime)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(escalation.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\"\(escalation.note)\"")
                                    .font(.subheadline)
                                    .italic()
                                Text("— \(escalation.actorEmail) (\(escalation.actorRoleAtTime))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pending Approvals by Team")
                        .font(.headline)
                    if d.pendingApprovalAgingByTeam.isEmpty {
                        Text("No pending department-approver steps.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(d.pendingApprovalAgingByTeam) { team in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(team.team.capitalized)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(team.pendingCount) pending")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let oldest = team.oldestPendingDays {
                                        Text("Oldest: \(oldest)d")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(oldest > 3 ? .red : .secondary)
                                    }
                                    if let avg = team.avgDaysPending {
                                        Text("Avg: \(String(format: "%.1f", avg))d")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color.gray.opacity(0.06))
                            .cornerRadius(6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }

    // MARK: - Section 2: Approval time vs. risk tier (validates the core thesis)

    @ViewBuilder
    private func approvalTimeSection(_ d: APIClient.DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approval Time by Risk Tier")
                .font(.title.bold())
            Text("Average time from submission to approval, grouped by supplier risk tier. Tap a tier below to see which orders drove it.")
                .font(.body)
                .foregroundColor(.secondary)

            let tierOrder = ["low", "medium", "high"]
            let chartData = tierOrder.compactMap { tier -> (String, Double)? in
                guard let value = d.avgApprovalTimeByTier[tier] ?? nil else { return nil }
                return (tier.capitalized, value)
            }

            if chartData.isEmpty {
                Text("Not enough decided orders yet to compare timing across tiers.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                Chart(chartData, id: \.0) { entry in
                    BarMark(
                        x: .value("Tier", entry.0),
                        y: .value("Days", entry.1)
                    )
                    .foregroundStyle(by: .value("Tier", entry.0))
                    .annotation(position: .top) {
                        Text(String(format: "%.2fd", entry.1))
                            .font(.headline)
                    }
                }
                .chartForegroundStyleScale([
                    "Low": Color.green, "Medium": Color.yellow, "High": Color.red
                ])
                .chartLegend(.hidden)
                .frame(height: 200)

                HStack(spacing: 0) {
                    ForEach(chartData, id: \.0) { entry in
                        Button {
                            selectedApprovalTimeTierForDrillDown = entry.0.lowercased()
                        } label: {
                            Label("View Orders", systemImage: "chevron.right.circle.fill")
                                .font(.headline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }

    // MARK: - Section 3: Exception drift — the core governance narrative

    @ViewBuilder
    private func exceptionDriftSection(_ d: APIClient.DashboardData) -> some View {
        let signals = d.exceptionDriftSignals

        VStack(alignment: .leading, spacing: 14) {
            Text("Exception Concentration")
                .font(.title.bold())
            Text("Suppliers and requesters repeatedly relying on the exception path within a \(signals.windowDays)-day window. Repetition here is worth attention, even when each approval looked reasonable on its own.")
                .font(.body)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 20) {
                supplierDriftList(signals)
                driftList(
                    title: "Requesters Repeatedly Using the Exception Path",
                    items: signals.topRequesters.map { (id: $0.requesterId, name: $0.requesterEmail, count: $0.count) },
                    onTap: { id, name in selectedRequesterDrillDown = DriftDrillDownTarget(id: id, name: name) }
                )
            }

            if !signals.triggerReasonDistribution.isEmpty {
                Divider()
                Text("What's Actually Getting Exempted")
                    .font(.title3.weight(.semibold))
                Text("If one reason dominates, the risk threshold itself may need recalibrating, not more exceptions.")
                    .font(.body)
                    .foregroundColor(.secondary)

                ForEach(signals.triggerReasonDistribution.sorted(by: { $0.value > $1.value }), id: \.key) { reason, count in
                    Button {
                        selectedTriggerReasonDrillDown = reason
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.6))
                            Text(reason.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.headline.weight(.medium))
                            Spacer()
                            Text("\(count)")
                                .font(.headline.weight(.bold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(Color.purple.opacity(0.06))
        .cornerRadius(10)
    }

    // A supplier granted one exception on a EUR 500k order and one granted
    // three exceptions on EUR 800 orders are not the same magnitude of risk
    // conversation — count alone conflated them. Also the actionable lever
    // this section was missing entirely: seeing the pattern led nowhere
    // before, now "Flag for Reassessment" does something.
    @ViewBuilder
    private func supplierDriftList(_ signals: APIClient.ExceptionDriftSignals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suppliers Repeatedly Granted Exceptions")
                .font(.title3.weight(.semibold))
            if signals.topSuppliers.isEmpty {
                Text("No repeated patterns in this window.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(signals.topSuppliers) { supplier in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            selectedSupplierDrillDown = DriftDrillDownTarget(id: supplier.supplierId, name: supplier.supplierName)
                        } label: {
                            HStack {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.headline)
                                    .foregroundColor(.blue.opacity(0.6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(supplier.supplierName)
                                        .font(.headline.weight(.medium))
                                        .lineLimit(1)
                                    Text("€\(String(format: "%.0f", supplier.totalAmountEur)) across \(supplier.count) exception\(supplier.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("×\(supplier.count)")
                                    .font(.headline.weight(.bold))
                                    .foregroundColor(supplier.count >= 2 ? .orange : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)

                        if flaggingSupplierId == supplier.supplierId {
                            HStack {
                                TextField("Why does this need reassessment?", text: $flagNoteText, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .lineLimit(1...3)
                                    .padding(6)
                                    .background(Color.gray.opacity(0.08))
                                    .cornerRadius(6)
                                Button("Flag") {
                                    Task { await flagSupplier(supplier.supplierId) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .controlSize(.small)
                                .disabled(flagNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Cancel") {
                                    flaggingSupplierId = nil
                                    flagNoteText = ""
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Button {
                                flaggingSupplierId = supplier.supplierId
                                flagNoteText = ""
                            } label: {
                                Label("Flag for Reassessment", systemImage: "exclamationmark.triangle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .controlSize(.small)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flagSupplier(_ supplierId: Int) async {
        do {
            _ = try await APIClient.shared.updateSupplierReassessment(
                id: supplierId, needsReassessment: true, reassessmentNote: flagNoteText
            )
        } catch {
            errorMessage = "Failed to flag supplier: \(error.localizedDescription)"
        }
        flaggingSupplierId = nil
        flagNoteText = ""
    }

    @ViewBuilder
    private func driftList(
        title: String,
        items: [(id: Int, name: String, count: Int)],
        onTap: @escaping (Int, String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            if items.isEmpty {
                Text("No repeated patterns in this window.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(items, id: \.id) { item in
                    Button {
                        onTap(item.id, item.name)
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.headline)
                                .foregroundColor(.blue.opacity(0.6))
                            Text(item.name)
                                .font(.headline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("×\(item.count)")
                                .font(.headline.weight(.bold))
                                .foregroundColor(item.count >= 2 ? .orange : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section 4: Risk distribution (background context, de-emphasized)

    @ViewBuilder
    private func riskDistributionSection(_ d: APIClient.DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supplier Risk Tier Distribution")
                .font(.title.bold())
            Text("How many suppliers fall into each risk tier. Concentration here flags where your supplier base needs closer oversight.")
                .font(.body)
                .foregroundColor(.secondary)

            let tierOrder = ["low", "medium", "high"]
            let pieData = tierOrder.compactMap { tier -> (String, Int)? in
                guard let count = d.riskTierDistribution[tier], count > 0 else { return nil }
                return (tier.capitalized, count)
            }

            if pieData.isEmpty {
                Text("No suppliers assessed yet.")
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 32) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(pieData, id: \.0) { entry in
                            let color: Color = entry.0 == "Low" ? .green : (entry.0 == "Medium" ? .yellow : .red)
                            Button {
                                selectedRiskTierForDrillDown = entry.0.lowercased()
                            } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(color).frame(width: 16, height: 16)
                                    Text("\(entry.0) Risk Suppliers: \(entry.1)")
                                        .font(.headline.weight(.medium))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                        }
                    }

                    Chart(pieData, id: \.0) { entry in
                        SectorMark(angle: .value("Count", entry.1), innerRadius: .ratio(0.6))
                            .foregroundStyle(by: .value("Tier", entry.0))
                    }
                    .chartForegroundStyleScale([
                        "Low": Color.green, "Medium": Color.yellow, "High": Color.red
                    ])
                    .chartLegend(.hidden)
                    .frame(width: 140, height: 140)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }

    // MARK: - Section 5: Risk-weighted spend exposure (amount, not headcount)

    private func tierColor(_ tier: String) -> Color {
        switch tier {
        case "low": return .green
        case "medium": return .yellow
        case "high": return .red
        default: return .secondary
        }
    }

    private func eurAmountString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "€\(Int(value))"
    }

    @ViewBuilder
    private func riskAmountExposureSection(_ d: APIClient.DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spend by Risk Tier")
                .font(.title.bold())
            Text("Where approved spend actually sits by risk tier. A few high-risk suppliers can matter more than their headcount suggests.")
                .font(.body)
                .foregroundColor(.secondary)

            let tierOrder = ["low", "medium", "high"]
            let amounts = tierOrder.map { d.riskTierAmountDistribution[$0] ?? 0 }
            let total = amounts.reduce(0, +)

            if total <= 0 {
                Text("No approved spend yet.")
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(zip(tierOrder, amounts)), id: \.0) { tier, amount in
                            if amount > 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(tierColor(tier))
                                    .frame(width: max(geo.size.width * CGFloat(amount / total), 4))
                            }
                        }
                    }
                }
                .frame(height: 28)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(zip(tierOrder, amounts)), id: \.0) { tier, amount in
                        HStack(spacing: 10) {
                            Circle().fill(tierColor(tier)).frame(width: 16, height: 16)
                            Text("\(tier.capitalized) Risk")
                                .font(.headline.weight(.medium))
                            Spacer()
                            Text(eurAmountString(amount))
                                .font(.headline.weight(.semibold))
                                .foregroundColor(.secondary)
                            Text(String(format: "%.0f%%", (amount / total) * 100))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            dashboard = try await APIClient.shared.fetchDashboard()
        } catch {
            errorMessage = "Failed to load dashboard: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
