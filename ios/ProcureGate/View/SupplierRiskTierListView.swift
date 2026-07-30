import SwiftUI

struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}

struct SupplierRiskTierListView: View {
    let tier: String
    @State private var suppliers: [APIClient.Supplier] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(suppliers) { supplier in
                VStack(alignment: .leading, spacing: 4) {
                    Text(supplier.name)
                        .font(.headline)
                    HStack {
                        Text(supplier.country ?? "—")
                        Text("·")
                        Text(supplier.category ?? "—")
                        Spacer()
                        Text(supplier.status.capitalized)
                            .foregroundColor(supplier.status == "blocked" ? .red : .secondary)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("\(tier.capitalized) Risk Suppliers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if isLoading { ProgressView() }
                if !isLoading && suppliers.isEmpty {
                    ContentUnavailableView("No suppliers", systemImage: "building.2")
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
            let all = try await APIClient.shared.fetchSuppliers()
            suppliers = all.filter { $0.computedRiskTier?.lowercased() == tier.lowercased() }
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
