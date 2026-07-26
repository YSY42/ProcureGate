import SwiftUI

struct CreatePurchaseOrderView: View {
    @Environment(\.dismiss) private var dismiss
    var onCreated: () -> Void

    @State private var supplierId = ""
    @State private var amount = ""
    @State private var currency = "EUR"
    @State private var description = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("New Purchase Order") {
                TextField("Supplier ID", text: $supplierId)
                TextField("Amount", text: $amount)
                TextField("Currency (e.g. EUR)", text: $currency)
                TextField("Description", text: $description)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Section {
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Create Purchase Order")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(supplierId.isEmpty || amount.isEmpty || description.isEmpty || isSubmitting)
                }
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 320)
    }

    private func submit() async {
        guard let supplierIdInt = Int(supplierId), let amountDouble = Double(amount) else {
            errorMessage = "Supplier ID must be a number, amount must be a valid number."
            return
        }

        isSubmitting = true
        errorMessage = nil

        do {
            _ = try await APIClient.shared.createPurchaseOrder(
                supplierId: supplierIdInt,
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
