import SwiftUI

/// Fetches a single supplier by id and shows its full profile. Backs the
/// Bypass Attempts drill-down: a blocked-creation attempt never produces a
/// PurchaseOrder row (create_purchase_order rejects before `db.add(po)`
/// runs), so there is no PO to link to — the supplier itself is the next
/// meaningful level of detail.
struct SupplierDetailView: View {
    let supplierId: Int
    @State private var supplier: APIClient.Supplier?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isEditingFlag = false
    @State private var flagNoteText = ""
    @Environment(\.dismiss) private var dismiss

    private var canEdit: Bool {
        APIClient.shared.currentUser?.role == "procurement_lead"
    }

    private func tierColor(_ tier: String?) -> Color {
        switch tier {
        case "low": return .green
        case "medium": return .yellow
        case "high": return .red
        default: return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let supplier {
                    List {
                        Section {
                            HStack {
                                Text("Status")
                                Spacer()
                                Text(supplier.status.capitalized)
                                    .foregroundColor(supplier.status == "blocked" ? .red : .secondary)
                            }
                            HStack {
                                Text("Risk Tier")
                                Spacer()
                                Text(supplier.computedRiskTier?.capitalized ?? "Not assessed")
                                    .foregroundColor(tierColor(supplier.computedRiskTier))
                            }
                            HStack {
                                Text("Country")
                                Spacer()
                                Text(supplier.country ?? "—").foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Category")
                                Spacer()
                                Text(supplier.category ?? "—").foregroundColor(.secondary)
                            }
                        }

                        Section("Assessment") {
                            HStack {
                                Text("Delivery Reliability")
                                Spacer()
                                Text(supplier.deliveryReliabilityScore.map { String(format: "%.0f", $0) } ?? "—")
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Defect Rate")
                                Spacer()
                                Text(supplier.defectRate.map { String(format: "%.1f", $0) } ?? "—")
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("ESG Rating")
                                Spacer()
                                Text(supplier.esgRating.map { String(format: "%.0f", $0) } ?? "—")
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Sanctions Flag")
                                Spacer()
                                Text(supplier.sanctionsFlag ? "Raised" : "Clear")
                                    .foregroundColor(supplier.sanctionsFlag ? .red : .secondary)
                            }
                        }

                        Section("Reassessment") {
                            reassessmentContent(supplier)
                        }
                    }
                    .navigationTitle(supplier.name)
                } else if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await load() }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            supplier = try await APIClient.shared.fetchSupplier(id: supplierId)
        } catch {
            errorMessage = "Could not load supplier #\(supplierId)."
        }
        isLoading = false
    }

    // A drift signal elsewhere (repeated exceptions) gives procurement_lead
    // a reason to distrust this supplier's current data — this is the lever
    // to act on that directly, not just a place to read the numbers.
    @ViewBuilder
    private func reassessmentContent(_ supplier: APIClient.Supplier) -> some View {
        if isEditingFlag {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Why does this need reassessment?", text: $flagNoteText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(8)
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(6)
                HStack {
                    Button("Cancel") {
                        isEditingFlag = false
                        flagNoteText = ""
                    }
                    Spacer()
                    Button("Save Flag") {
                        Task { await saveFlag(needsReassessment: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(flagNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } else if supplier.needsReassessment {
            VStack(alignment: .leading, spacing: 6) {
                Label("Flagged for Reassessment", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                if let note = supplier.reassessmentNote, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if canEdit {
                    Button("Clear Flag") {
                        Task { await saveFlag(needsReassessment: false) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else if canEdit {
            Button {
                isEditingFlag = true
                flagNoteText = ""
            } label: {
                Label("Flag for Reassessment", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        } else {
            Text("Not flagged")
                .foregroundColor(.secondary)
        }
    }

    private func saveFlag(needsReassessment: Bool) async {
        do {
            supplier = try await APIClient.shared.updateSupplierReassessment(
                id: supplierId, needsReassessment: needsReassessment, reassessmentNote: needsReassessment ? flagNoteText : nil
            )
        } catch {
            errorMessage = "Failed to update flag: \(error.localizedDescription)"
        }
        isEditingFlag = false
        flagNoteText = ""
    }
}
