import SwiftUI

// Self-service calibration of the risk model itself (research.md's own
// stated fix for trigger-reason concentration on compliance floor: adjust
// the threshold, not keep approving exceptions against it) — previously
// this required an engineer editing app/config.py and redeploying.
struct RiskSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var floorText = ""
    @State private var currentFloor: Double?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The compliance floor is the ESG rating below which a supplier is hard-blocked, regardless of risk tier. If blocks are concentrating on this one reason, the model itself may need recalibrating — this changes it for every future submission, so use it deliberately.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("ESG Compliance Floor (0–100)") {
                    if let currentFloor {
                        Text("Currently in effect: \(String(format: "%.1f", currentFloor))")
                            .foregroundColor(.secondary)
                    } else {
                        Text("Currently in effect: default (no override set)")
                            .foregroundColor(.secondary)
                    }
                    TextField("New floor", text: $floorText)
                        .textFieldStyle(.plain)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("Risk Model Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(Double(floorText) == nil || isSaving)
                }
            }
            .task { await load() }
            .overlay {
                if isLoading { ProgressView() }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let settings = try await APIClient.shared.fetchRiskSettings()
            currentFloor = settings.esgComplianceFloor
            if let floor = settings.esgComplianceFloor {
                floorText = String(format: "%.1f", floor)
            }
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func save() async {
        guard let value = Double(floorText) else { return }
        isSaving = true
        errorMessage = nil
        do {
            let updated = try await APIClient.shared.updateRiskSettings(esgComplianceFloor: value)
            currentFloor = updated.esgComplianceFloor
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
        isSaving = false
    }
}
