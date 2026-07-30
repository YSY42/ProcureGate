//
//  PurchaseOrder.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import Foundation

struct ApprovalStep: Codable, Identifiable, Hashable {
    var id: Int { stepNumber }
    let stepNumber: Int
    let requiredRole: String
    let status: String
    let decidedById: Int?
    let decidedAt: String?

    enum CodingKeys: String, CodingKey {
        case stepNumber = "step_number"
        case requiredRole = "required_role"
        case status
        case decidedById = "decided_by_id"
        case decidedAt = "decided_at"
    }
}

struct PurchaseOrder: Codable, Identifiable, Hashable {
    let id: Int
    let requesterId: Int
    let requesterEmail: String
    let supplierId: Int
    let supplierName: String
    let supplierRiskTier: String?
    let supplierInherentRiskTier: String
    let supplierPerformanceRiskTier: String?
    let supplierComplianceRiskTier: String?
    let amount: String
    let currency: String
    let description: String
    let status: String
    let approvalControlStatus: String?
    let approvedWithException: Bool
    let currentStepNumber: Int?
    let createdAt: String
    let submittedAt: String?
    let decidedAt: String?
    let approvalSteps: [ApprovalStep]

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case requesterEmail = "requester_email"
        case supplierId = "supplier_id"
        case supplierName = "supplier_name"
        case supplierRiskTier = "supplier_risk_tier"
        case supplierInherentRiskTier = "supplier_inherent_risk_tier"
        case supplierPerformanceRiskTier = "supplier_performance_risk_tier"
        case supplierComplianceRiskTier = "supplier_compliance_risk_tier"
        case amount, currency, description, status
        case approvalControlStatus = "approval_control_status"
        case approvedWithException = "approved_with_exception"
        case currentStepNumber = "current_step_number"
        case createdAt = "created_at"
        case submittedAt = "submitted_at"
        case decidedAt = "decided_at"
        case approvalSteps = "approval_steps"
    }
}
