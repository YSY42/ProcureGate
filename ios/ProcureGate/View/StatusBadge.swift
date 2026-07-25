//
//  StatusBadge.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import SwiftUI

struct StatusBadge: View {
    let status: RiskStatus

    var body: some View {
        Label(status.label, systemImage: status.icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(status.color.opacity(0.15))
            .foregroundColor(status.color)
            .clipShape(Capsule())
    }
}
