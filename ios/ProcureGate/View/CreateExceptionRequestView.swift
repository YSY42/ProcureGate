//
//  CreateExceptionRequestView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 26/07/2026.
//

import SwiftUI

struct CreateExceptionRequestView: View {
    @Environment(\.dismiss) private var dismiss
    let poId: Int
    var onSubmitted: () -> Void

    @State private var justification = ""
    @State private var urgency = "medium"
    @State private var expiryDate = Date().addingTimeInterval(7 * 24 * 60 * 60) // default: 7 days out
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let urgencyOptions = ["low", "medium", "high"]

    var body: some View {
        Form {
            Section("Exception Request for PO #\(poId)") {
                TextField("Justification", text: $justification, axis: .vertical)
                    .lineLimit(3...6)

                Picker("Urgency", selection: $urgency) {
                    ForEach(urgencyOptions, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }

                DatePicker("Expires", selection: $expiryDate, in: Date()..., displayedComponents: .date)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Section {
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Submit Request")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(justification.isEmpty || isSubmitting)
                }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 320)
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil

        let formatter = ISO8601DateFormatter()
        let expiryString = formatter.string(from: expiryDate)

        do {
            _ = try await APIClient.shared.submitExceptionRequest(
                poId: poId, justification: justification, urgency: urgency, expiryAt: expiryString
            )
            onSubmitted()
            dismiss()
        } catch {
            errorMessage = "Failed to submit: \(error.localizedDescription)"
        }

        isSubmitting = false
    }
}
