import SwiftUI

struct CreatePurchaseOrderView: View {
    @Environment(\.dismiss) private var dismiss
    var onCreated: () -> Void

    @State private var suppliers: [APIClient.Supplier] = []
    @State private var isLoadingSuppliers = false
    @State private var supplierSearchText = ""
    @State private var selectedSupplier: APIClient.Supplier?

    @State private var requesterDashboard: APIClient.RequesterDashboardData?

    @State private var amount = ""
    @State private var currency = "EUR"
    @State private var description: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let prefillSupplierId: Int?

    init(prefillSupplierId: Int? = nil, prefillDescription: String = "", onCreated: @escaping () -> Void) {
        self.prefillSupplierId = prefillSupplierId
        _description = State(initialValue: prefillDescription)
        self.onCreated = onCreated
    }

    private var filteredSuppliers: [APIClient.Supplier] {
        guard !supplierSearchText.isEmpty else { return suppliers }
        return suppliers.filter { supplier in
            supplier.name.localizedCaseInsensitiveContains(supplierSearchText)
                || String(supplier.id).contains(supplierSearchText)
        }
    }

    // Reuses the requester's own trigger-reason history (already computed by
    // the backend for the personal dashboard) to surface a pattern the
    // buyer would otherwise only discover by hitting "submit" and getting
    // blocked again — same data, moved from a passive query to a proactive
    // warning at the moment it's actionable (before submit).
    private var repeatBlockWarning: String? {
        guard let selectedSupplier, let dashboard = requesterDashboard else { return nil }
        let poSupplierMap = Dictionary(uniqueKeysWithValues: dashboard.myPurchaseOrders.map { ($0.id, $0.supplierId) })
        let matching = dashboard.myTriggerReasonDetails.filter { poSupplierMap[$0.poId] == selectedSupplier.id }
        guard !matching.isEmpty else { return nil }

        let counts = Dictionary(grouping: matching, by: { $0.actionType }).mapValues { $0.count }
        let reasons = counts
            .sorted { $0.value > $1.value }
            .map { "\(triggerReasonLabel($0.key)) (\($0.value)x)" }
            .joined(separator: ", ")
        return "You've had \(matching.count) order\(matching.count == 1 ? "" : "s") blocked for this "
            + "supplier before — \(reasons)"
    }

    private func triggerReasonLabel(_ actionType: String) -> String {
        switch actionType {
        case "risk_trigger_compliance_floor": return "compliance floor"
        case "risk_trigger_stale": return "stale assessment"
        case "risk_trigger_incomplete_or_unassessed": return "incomplete assessment"
        default: return actionType.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func riskBadge(_ supplier: APIClient.Supplier) -> (label: String, icon: String, color: Color) {
        if supplier.status == "blocked" {
            return ("Blocked", "hand.raised.fill", .red)
        }
        switch supplier.computedRiskTier {
        case "low": return ("Low risk", "checkmark.circle.fill", .green)
        case "medium": return ("Medium risk", "exclamationmark.circle.fill", .yellow)
        case "high": return ("High risk", "exclamationmark.triangle.fill", .red)
        default: return ("Unassessed", "questionmark.circle", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Purchase Order")
                        .font(.title.bold())
                    Text("Submitted orders are automatically routed by supplier risk.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SUPPLIER")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)

                        if let selectedSupplier {
                            let badge = riskBadge(selectedSupplier)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(selectedSupplier.name)
                                        .font(.title3.weight(.semibold))
                                    HStack(spacing: 6) {
                                        Text("Supplier #\(selectedSupplier.id)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("·")
                                            .foregroundColor(.secondary)
                                        Label(badge.label, systemImage: badge.icon)
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(badge.color)
                                    }
                                }
                                Spacer()
                                Button("Change") {
                                    self.selectedSupplier = nil
                                    supplierSearchText = ""
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(12)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(8)

                            if selectedSupplier.status == "blocked" {
                                warningBanner(
                                    "This supplier is currently blocked. Submitting will very likely "
                                        + "require an exception request after review.",
                                    color: .red, icon: "hand.raised.fill"
                                )
                            } else if selectedSupplier.computedRiskTier == "high" {
                                warningBanner(
                                    "This supplier is currently High risk. Expect additional approval "
                                        + "steps before this order clears.",
                                    color: .orange, icon: "exclamationmark.triangle.fill"
                                )
                            }

                            if let repeatBlockWarning {
                                warningBanner(repeatBlockWarning, color: .orange, icon: "clock.arrow.circlepath")
                            }
                        } else {
                            TextField("Search suppliers by name or #ID…", text: $supplierSearchText)
                                .textFieldStyle(.plain)
                                .font(.title3)
                                .padding(12)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(8)

                            if isLoadingSuppliers {
                                ProgressView().padding(.top, 8)
                            } else if filteredSuppliers.isEmpty {
                                Text("No matching suppliers.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(filteredSuppliers) { supplier in
                                            supplierRow(supplier)
                                        }
                                    }
                                }
                                .frame(maxHeight: 180)
                            }
                        }
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AMOUNT")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.secondary)
                            TextField("0.00", text: $amount)
                                .textFieldStyle(.plain)
                                .font(.title3)
                                .padding(12)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(8)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CURRENCY")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.secondary)
                            TextField("EUR", text: $currency)
                                .textFieldStyle(.plain)
                                .font(.title3)
                                .padding(12)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(8)
                                .frame(width: 100)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("DESCRIPTION")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                        TextField("What is this order for?", text: $description)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .padding(12)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(8)
                    }

                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorMessage)
                        }
                        .font(.subheadline)
                        .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 24)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

                Spacer()

                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(width: 160)
                    } else {
                        Text("Create Purchase Order")
                            .frame(width: 160)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSupplier == nil || amount.isEmpty || description.isEmpty || isSubmitting)
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 560)
        .task {
            await loadSuppliers()
            await loadRequesterDashboardIfApplicable()
        }
    }

    @ViewBuilder
    private func supplierRow(_ supplier: APIClient.Supplier) -> some View {
        let badge = riskBadge(supplier)
        Button {
            selectedSupplier = supplier
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(supplier.name)
                        .font(.body.weight(.medium))
                    Text("Supplier #\(supplier.id)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Label(badge.label, systemImage: badge.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(badge.color)
            }
            .padding(8)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func warningBanner(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .font(.subheadline)
        }
        .foregroundColor(color)
        .padding(10)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }

    private func loadSuppliers() async {
        isLoadingSuppliers = true
        do {
            suppliers = try await APIClient.shared.fetchSuppliers()
            if let prefillSupplierId {
                selectedSupplier = suppliers.first { $0.id == prefillSupplierId }
            }
        } catch {
            errorMessage = "Failed to load suppliers: \(error.localizedDescription)"
        }
        isLoadingSuppliers = false
    }

    // The repeat-block hint is specifically about the buyer's own submission
    // history — only meaningful (and only reliably decodable, since the
    // dashboard payload shape differs by role) for the requester role.
    private func loadRequesterDashboardIfApplicable() async {
        guard APIClient.shared.currentUser?.role == "requester" else { return }
        requesterDashboard = try? await APIClient.shared.fetchRequesterDashboard()
    }

    private func submit() async {
        guard let selectedSupplier else {
            errorMessage = "Select a supplier."
            return
        }
        guard let amountDouble = Double(amount) else {
            errorMessage = "Amount must be a valid number."
            return
        }

        isSubmitting = true
        errorMessage = nil

        do {
            _ = try await APIClient.shared.createPurchaseOrder(
                supplierId: selectedSupplier.id,
                amount: amountDouble,
                currency: currency,
                description: description
            )
            onCreated()
            dismiss()
        } catch {
            errorMessage = "Failed to create: \(error.localizedDescription)"
        }

        isSubmitting = false
    }
}
