import SwiftUI

struct ContentView: View {
    var client = APIClient.shared
    @State private var purchaseOrders: [PurchaseOrder] = []
    @State private var selectedID: PurchaseOrder.ID?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasEnteredWorkspace = false

    private var selectedPO: PurchaseOrder? {
        purchaseOrders.first(where: { $0.id == selectedID })
    }

    var body: some View {
            if client.accessToken != nil {
                if client.currentUser == nil {
                    ProgressView("Loading profile…")
                } else if !hasEnteredWorkspace && (client.currentUser?.role == "procurement_lead" || client.currentUser?.role == "auditor") {
                    dashboardHomeScreen
                } else if client.currentUser?.role == "auditor" {
                    TabView {
                        AuditLogView(onReturnToDashboard: { hasEnteredWorkspace = false })
                            .tabItem { Label("Audit Trail", systemImage: "list.bullet.rectangle") }
                        DashboardView()
                            .tabItem { Label("Dashboard", systemImage: "chart.bar") }
                    }
                } else {
                    poListSplitView
                }
            } else {
                LoginView()
            }
        }
    
    private var dashboardHomeScreen: some View {
        VStack(spacing: 0) {
            DashboardView()

            Button {
                hasEnteredWorkspace = true
            } label: {
                Label(
                    client.currentUser?.role == "auditor" ? "Enter Audit Trail" : "Enter Purchase Order Approval",
                    systemImage: "arrow.right.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private var poListSplitView: some View {
            NavigationSplitView {
                PurchaseOrderListView(
                    purchaseOrders: purchaseOrders,
                    selection: $selectedID,
                    isLoading: isLoading,
                    errorMessage: $errorMessage,
                    onReload: { await loadPurchaseOrders() }
                )
            } detail: {
                VStack(spacing: 0) {
                    backToDashboardBar

                    if let selectedPO {
                        PurchaseOrderDetailView(po: selectedPO) {
                            Task { await loadPurchaseOrders() }
                        }
                    } else {
                        Text("Select a purchase order")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .task {
                await loadPurchaseOrders()
            }
        }

        private var backToDashboardBar: some View {
            HStack {
                Button {
                    hasEnteredWorkspace = false
                } label: {
                    Label("Back to Dashboard", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                Spacer()
            }
            .padding(10)
            .background(Color.gray.opacity(0.08))
        }

    private func loadPurchaseOrders() async {
        isLoading = true
        errorMessage = nil
        do {
            purchaseOrders = try await APIClient.shared.fetchPurchaseOrders()
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

#Preview {
    ContentView()
}
