//
//  PersonalRiskSummaryView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 27/07/2026.
//

import SwiftUI

struct PersonalRiskSummaryView: View {
    let title: String
    let controlStatusBreakdown: [String: Int]
    let triggerReasonBreakdown: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            let tiers = ["allowed", "conditional", "escalated", "blocked"]
            let total = controlStatusBreakdown.values.reduce(0, +)

            if total == 0 {
                Text("No submitted orders yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(tiers, id: \.self) { tier in
                        let count = controlStatusBreakdown[tier] ?? 0
                        if count > 0 {
                            let risk = RiskStatus(rawValue: tier)
                            VStack(spacing: 2) {
                                Text("\(count)")
                                    .font(.title3.bold())
                                    .foregroundColor(risk.color)
                                Text(risk.label)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                if let blockedCount = controlStatusBreakdown["blocked"], blockedCount > 0,
                   !triggerReasonBreakdown.isEmpty {
                    Divider()
                    Text("Why your orders got blocked:")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    ForEach(triggerReasonBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { reason, count in
                        HStack {
                            Text(reason.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption2)
                            Spacer()
                            Text("\(count)")
                                .font(.caption2.weight(.bold))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(10)
    }
}
