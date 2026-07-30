//
//  BlockedAttemptsDetailView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 27/07/2026.
//

import SwiftUI

struct BlockedAttemptsDetailView: View {
    let details: [APIClient.BlockedAttemptDetail]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(details) { detail in
                NavigationLink(value: detail.supplierId) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail.supplierName)
                            .font(.headline)
                        Text(detail.rationale)
                            .font(.subheadline)
                        HStack {
                            Text("Attempted by: \(detail.actorEmail)")
                            Spacer()
                            Text(detail.at.asFormattedDateTime)
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Bypass Attempts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(for: Int.self) { supplierId in
                SupplierDetailView(supplierId: supplierId)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}
