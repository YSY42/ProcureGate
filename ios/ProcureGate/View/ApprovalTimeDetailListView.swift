import SwiftUI

struct ApprovalTimeDetailListView: View {
    let tier: String
    @State private var details: [APIClient.ApprovalTimeDetail] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(details) { detail in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("PO #\(detail.poId)")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.2fd", detail.daysToDecision))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    Text(detail.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("\(detail.supplierName) · \(detail.amount) \(detail.currency)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(detail.decidedAt.asFormattedDateTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("\(tier.capitalized) Tier Approval Times")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if details.isEmpty {
                    ContentUnavailableView("No decided orders", systemImage: "clock.badge.questionmark")
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await load() }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            details = try await APIClient.shared.fetchApprovalTimeDetails(tier: tier)
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
