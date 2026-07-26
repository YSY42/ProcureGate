//
//  RiskStatus.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import SwiftUI

enum RiskStatus {
    case allowed, conditional, escalated, blocked, draft, unknown

    init(rawValue: String?) {
        switch rawValue {
        case "allowed": self = .allowed
        case "conditional": self = .conditional
        case "escalated": self = .escalated
        case "blocked": self = .blocked
        case nil: self = .draft
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .conditional: "Conditional"
        case .escalated: "Escalated"
        case .blocked: "Blocked"
        case .draft: "Draft"
        case .unknown: "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .allowed: "checkmark.circle.fill"
        case .conditional: "exclamationmark.circle.fill"
        case .escalated: "arrow.up.circle.fill"
        case .blocked: "xmark.circle.fill"
        case .draft: "doc.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .allowed: .green
        case .conditional: .yellow
        case .escalated: .orange
        case .blocked: .red
        case .draft, .unknown: .gray
        }
    }
}
