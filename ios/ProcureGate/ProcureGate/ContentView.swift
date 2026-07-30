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
            Group {
                if client.accessToken != nil {
                    if client.currentUser == nil {
                        ProgressView("Loading profile…")
                    } else if !hasEnteredWorkspace {
                        homeScreen
                    } else if client.currentUser?.role == "auditor" {
                        AuditLogView(onReturnToDashboard: { hasEnteredWorkspace = false })
                    } else {
                        poListSplitView
                    }
                } else {
                    LoginView()
                }
            }
            .task(id: client.accessToken) {
                if client.accessToken != nil {
                    POStatusNotifier.shared.requestAuthorizationIfNeeded()
                    POStatusNotifier.shared.startPolling()
                } else {
                    POStatusNotifier.shared.stopPolling()
                }
            }
        }

        @ViewBuilder
        private var homeScreen: some View {
            switch client.currentUser?.role {
            case "procurement_lead", "auditor":
                dashboardHomeScreen
            case "requester":
                PersonalDashboardView(scope: .requester) { hasEnteredWorkspace = true }
            case "department_approver":
                PersonalDashboardView(scope: .approver) { hasEnteredWorkspace = true }
            default:
                poListSplitView // fallback, shouldn't normally hit this
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
                    onReload: { await loadPurchaseOrders() },
                    onBackToDashboard: { hasEnteredWorkspace = false }
                )
            } detail: {
                if let selectedPO {
                    PurchaseOrderDetailView(po: selectedPO) {
                        Task { await loadPurchaseOrders() }
                    }
                } else {
                    ContentUnavailableView(
                        "Select a Purchase Order",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Choose an order from the list to view its details and approval status.")
                    )
                }
            }
            .task {
                await loadPurchaseOrders()
            }
            .onAppear {
                POStatusNotifier.shared.markAllSeen()
            }
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
