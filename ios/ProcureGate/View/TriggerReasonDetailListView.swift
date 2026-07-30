import SwiftUI

struct TriggerReasonDetailListView: View {
    let reason: String
    let details: [APIClient.TriggerReasonDetail]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(details.enumerated()), id: \.offset) { _, detail in
                NavigationLink(value: detail.poId) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PO #\(detail.poId)")
                            .font(.headline)
                        Text(summary(for: detail))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(detail.at.asFormattedDateTime)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(reason.replacingOccurrences(of: "_", with: " ").capitalized)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if details.isEmpty {
                    ContentUnavailableView("No matching entries", systemImage: "doc.text.magnifyingglass")
                }
            }
            .navigationDestination(for: Int.self) { poId in
                POLoadingDetailView(poId: poId)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    /// Falls back to the raw rationale when metadata is missing or action_type is unrecognized.
    private func summary(for detail: APIClient.TriggerReasonDetail) -> String {
        guard let metadata = detail.metadata else { return detail.rationale }

        switch detail.actionType {
        case "risk_trigger_compliance_floor":
            var pieces: [String] = []
            if let esg = metadata["esg_rating"] {
                pieces.append("ESG rating \(esg.displayString) (below floor)")
            }
            if case .bool(let sanctioned)? = metadata["sanctions_flag"] {
                pieces.append(sanctioned ? "Sanctions flag raised" : "No sanctions flag")
            }
            return pieces.isEmpty ? detail.rationale : pieces.joined(separator: " · ")

        case "risk_trigger_stale":
            var pieces: [String] = []
            if let age = metadata["age_days"] {
                pieces.append("Last assessed \(age.displayString)d ago")
            }
            if let window = metadata["staleness_window_days"] {
                pieces.append("window \(window.displayString)d")
            }
            if let tier = metadata["last_computed_tier"] {
                pieces.append("last tier: \(tier.displayString)")
            }
            return pieces.isEmpty ? detail.rationale : pieces.joined(separator: " · ")

        case "risk_trigger_incomplete_or_unassessed":
            if let validity = metadata["validity"] {
                return "Assessment \(validity.displayString)"
            }
            return detail.rationale

        default:
            return detail.rationale
        }
    }
}
