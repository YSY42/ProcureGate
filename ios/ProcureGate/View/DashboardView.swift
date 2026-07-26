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

    var body: some View {
            NavigationStack {
                ScrollView {
                    if let dashboard {
                        VStack(alignment: .leading, spacing: 20) {
                            alertCardsSection(dashboard)
                            approvalTimeSection(dashboard)
                            exceptionDriftSection(dashboard)
                            riskDistributionSection(dashboard)
                        }
                        .padding()
                    } else if !isLoading {
                        ContentUnavailableView("No data", systemImage: "chart.bar")
                    }
                }
                .navigationTitle("Governance Dashboard")
                .toolbar {
                    ToolbarItem {
                        Button("Refresh") {
                            Task { await load() }
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
            }
        }

    // MARK: - Section 1: Control-effectiveness alert cards (highest priority)

    @ViewBuilder
    private func alertCardsSection(_ d: APIClient.DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Control Effectiveness")
                .font(.title2.bold())

            HStack(spacing: 12) {
                alertCard(
                    title: "Bypass Attempts Stopped",
                    value: "\(d.blockedCreationAttempts)",
                    detail: "PO creation attempts against a blocked supplier, rejected before any risk score was computed.",
                    icon: "hand.raised.fill",
                    tint: d.blockedCreationAttempts > 0 ? .green : .secondary
                )
                alertCard(
                    title: "Orders Blocked on Unreliable Supplier Data",
                    value: "\(d.posAffectedByStaleOrUnassessed)",
                    detail: "This signal depends on real time passing before assessment data ages out — by design, it can't be manually triggered in this demo environment.",
                    icon: "clock.badge.exclamationmark",
                    tint: .secondary
                )
            }
        }
    }

    @ViewBuilder
    private func alertCard(title: String, value: String, detail: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Spacer()
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - Section 2: Approval time vs. risk tier (validates the core thesis)

    @ViewBuilder
    private func approvalTimeSection(_ d: APIClient.DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approval Time by Risk Tier")
                .font(.title2.bold())
            Text("Average time from submission to approval, grouped by supplier risk tier.")
                .font(.caption)
                .foregroundColor(.secondary)

            let tierOrder = ["low", "medium", "high"]
            let chartData = tierOrder.compactMap { tier -> (String, Double)? in
                guard let value = d.avgApprovalTimeByTier[tier] ?? nil else { return nil }
                return (tier.capitalized, value)
            }

            if chartData.isEmpty {
                Text("Not enough decided orders yet to compare timing across tiers.")
                    .font(.caption)
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
                            .font(.caption2)
                    }
                }
                .chartForegroundStyleScale([
                    "Low": Color.green, "Medium": Color.yellow, "High": Color.red
                ])
                .frame(height: 180)
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

        VStack(alignment: .leading, spacing: 12) {
            Text("Exception Concentration")
                .font(.title2.bold())
            Text("Suppliers and requesters repeatedly relying on the exception path within a \(signals.windowDays)-day window — repetition here is worth attention even when each approval looked reasonable on its own.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 16) {
                driftList(
                    title: "Suppliers Repeatedly Granted Exceptions",
                    items: signals.topSuppliers.map { ($0.supplierName, $0.count) }
                )
                driftList(
                    title: "Requesters Repeatedly Using the Exception Path",
                    items: signals.topRequesters.map { ($0.requesterEmail, $0.count) }
                )
            }

            if !signals.triggerReasonDistribution.isEmpty {
                Divider()
                Text("What's Actually Getting Exempted")
                    .font(.subheadline.weight(.semibold))
                Text("If one reason dominates, the risk threshold itself may need recalibrating — not more exceptions.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(signals.triggerReasonDistribution.sorted(by: { $0.value > $1.value }), id: \.key) { reason, count in
                    HStack {
                        Text(reason.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption)
                        Spacer()
                        Text("\(count)")
                            .font(.caption.weight(.bold))
                    }
                }
            }
        }
        .padding()
        .background(Color.purple.opacity(0.06))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func driftList(title: String, items: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            if items.isEmpty {
                Text("No repeated patterns in this window.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ForEach(items, id: \.0) { name, count in
                    HStack {
                        Text(name)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer()
                        Text("×\(count)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(count >= 2 ? .orange : .secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section 4: Risk distribution (background context, de-emphasized)

    @ViewBuilder
    private func riskDistributionSection(_ d: APIClient.DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Supplier Risk Tier Distribution")
                .font(.headline)
                .foregroundColor(.secondary)

            let tierOrder = ["low", "medium", "high"]
            let pieData = tierOrder.compactMap { tier -> (String, Int)? in
                guard let count = d.riskTierDistribution[tier], count > 0 else { return nil }
                return (tier.capitalized, count)
            }

            if pieData.isEmpty {
                Text("No suppliers assessed yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Chart(pieData, id: \.0) { entry in
                    SectorMark(angle: .value("Count", entry.1), innerRadius: .ratio(0.6))
                        .foregroundStyle(by: .value("Tier", entry.0))
                }
                .chartForegroundStyleScale([
                    "Low": Color.green, "Medium": Color.yellow, "High": Color.red
                ])
                .frame(height: 140)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.03))
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
