import SwiftUI

/// Fetches a single purchase order by id and shows its full detail view.
/// Backs drill-down lists (exception/trigger-reason details) that only
/// carry a po_id, not the full PurchaseOrder object.
struct POLoadingDetailView: View {
    let poId: Int
    @State private var po: PurchaseOrder?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let po {
                PurchaseOrderDetailView(po: po)
            } else if let errorMessage {
                ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
            } else if isLoading {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            po = try await APIClient.shared.fetchPurchaseOrder(id: poId)
        } catch {
            errorMessage = "Could not load PO #\(poId)."
        }
        isLoading = false
    }
}
