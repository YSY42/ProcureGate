import SwiftUI

struct ExceptionDetailListView: View {
    enum Kind {
        case supplier(id: Int, name: String)
        case requester(id: Int, email: String)
    }

    let kind: Kind
    @State private var details: [APIClient.ExceptionDetail] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch kind {
        case .supplier(_, let name): return name
        case .requester(_, let email): return email
        }
    }

    var body: some View {
        NavigationStack {
            List(Array(details.enumerated()), id: \.offset) { _, detail in
                NavigationLink(value: detail.poId) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PO #\(detail.poId)")
                            .font(.headline)
                        Text(detail.justification)
                            .font(.subheadline)
                        if let decidedAt = detail.decidedAt {
                            Text(decidedAt.asFormattedDateTime)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if isLoading { ProgressView() }
                if !isLoading && details.isEmpty {
                    ContentUnavailableView("No approved exceptions", systemImage: "checkmark.seal")
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await load() }
            .navigationDestination(for: Int.self) { poId in
                POLoadingDetailView(poId: poId)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            switch kind {
            case .supplier(let id, _):
                details = try await APIClient.shared.fetchSupplierExceptionDetails(supplierId: id)
            case .requester(let id, _):
                details = try await APIClient.shared.fetchRequesterExceptionDetails(requesterId: id)
            }
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
