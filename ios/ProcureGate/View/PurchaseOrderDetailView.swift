//
//  PurchaseOrderDetailView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import SwiftUI

struct PurchaseOrderDetailView: View {
    let po: PurchaseOrder
    var onActionCompleted: (() -> Void)? = nil
    @State private var isProcessing = false
    @State private var actionError: String?
    @State private var updatedPO: PurchaseOrder?
    @State private var showingExceptionSheet = false

    var body: some View {
        Form {
            Section("Order") {
                LabeledContent("PO Number", value: "#\(po.id)")
                LabeledContent("Description", value: po.description)
                LabeledContent("Amount", value: "\(po.amount) \(po.currency)")
                LabeledContent("Status", value: po.status.capitalized)
                if let controlStatus = po.approvalControlStatus {
                    LabeledContent("Risk Control Status", value: controlStatus.capitalized)
                }
                LabeledContent("Approved with Exception", value: po.approvedWithException ? "Yes" : "No")
            }
            
            if let currentStep = po.approvalSteps.first(where: { $0.status == "pending" }),
                           currentStep.requiredRole == APIClient.shared.currentUser?.role {
                            Section("Your Action Required") {
                                HStack {
                                    Button("Approve") {
                                        Task { await performTransition(action: "approve") }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)

                                    Button("Reject") {
                                        Task { await performTransition(action: "reject") }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                }
                                if isProcessing {
                                    ProgressView()
                                }
                                if let actionError {
                                    Text(actionError)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                }
                            }
                        }
            
            if po.approvalControlStatus == "blocked" && po.status != "approved" && po.status != "rejected" {
                Section("Blocked — No Pending Approval Step") {
                    Text("This PO cannot proceed through normal approval. Submit an exception request with justification to route it to an independent procurement lead for review.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Request Exception") {
                        showingExceptionSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            
            if !po.approvalSteps.isEmpty {
                Section("Approval Steps") {
                    ForEach(po.approvalSteps) { step in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Step \(step.stepNumber): \(step.requiredRole)")
                                    .font(.subheadline)
                                if let decidedById = step.decidedById {
                                    Text("Decided by user #\(decidedById)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Text(step.status.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(step.status == "approved" ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
            } else {
                Section {
                    Text("No approval steps recorded.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("PO #\(po.id)")
        .sheet(isPresented: $showingExceptionSheet) {
            CreateExceptionRequestView(poId: po.id) {
                onActionCompleted?()
            }
        }
            }

        private func performTransition(action: String) async {
                        isProcessing = true
                        actionError = nil
                        do {
                            updatedPO = try await APIClient.shared.transitionPurchaseOrder(poId: po.id, action: action)
                            onActionCompleted?()
                        } catch {
                            actionError = error.localizedDescription
                        }
                        isProcessing = false
                    }
        }
