import SwiftUI

struct PurchaseOrderTierDrillDownView: View {
    let tier: String
    let orders: [PurchaseOrder]
    var onActionCompleted: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(orders) { po in
                NavigationLink(value: po.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PO #\(po.id) · \(po.amount) \(po.currency)")
                            .font(.headline)
                        Text(po.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Text(po.status.capitalized)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationDestination(for: Int.self) { poId in
                if let po = orders.first(where: { $0.id == poId }) {
                    PurchaseOrderDetailView(po: po, onActionCompleted: onActionCompleted)
                }
            }
            .navigationTitle("\(RiskStatus(rawValue: tier).label) Orders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if orders.isEmpty {
                    ContentUnavailableView("No orders", systemImage: "doc.text")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}            
