//
//  APIClient.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import Foundation

enum APIError: Error, LocalizedError {
    case invalidResponse
    case unauthorized
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .unauthorized: return "Not authorized"
        case .serverError(let message): return message
        }
    }
}

/// Decodes an arbitrary JSON scalar (string/int/double/bool/null).
enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var displayString: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "Yes" : "No"
        case .null: return "—"
        }
    }
}

@Observable
class APIClient {
    static let shared = APIClient()
    
    // 换成你Render上的真实部署地址,先用这个占位
    private let baseURL = "http://localhost:8000"
    
    var accessToken: String?
    
    private init() {}
    
    func login(email: String, password: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/v1/auth/login") else {
            throw APIError.invalidResponse
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyString = "username=\(email)&password=\(password)"
        request.httpBody = bodyString.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError("Login failed with status \(httpResponse.statusCode)")
        }
        
        let decoder = JSONDecoder()
        let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
        self.accessToken = tokenResponse.accessToken
        try await fetchCurrentUser()
    }

    func logout() {
        accessToken = nil
        currentUser = nil
    }


    func fetchPurchaseOrders() async throws -> [PurchaseOrder] {
        guard let url = URL(string: "\(baseURL)/api/v1/purchase-orders") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.serverError("Failed to fetch purchase orders")
        }
        
        return try JSONDecoder().decode([PurchaseOrder].self, from: data)
    }
    
    
    func fetchPurchaseOrder(id: Int) async throws -> PurchaseOrder {
            guard let url = URL(string: "\(baseURL)/api/v1/purchase-orders/\(id)") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch purchase order #\(id)")
            }
            return try JSONDecoder().decode(PurchaseOrder.self, from: data)
        }
    
    
    struct CreatePORequest: Codable {
        let supplierId: Int
        let amount: Double
        let currency: String
        let description: String

        enum CodingKeys: String, CodingKey {
            case supplierId = "supplier_id"
            case amount, currency, description
        }
    }

    func createPurchaseOrder(supplierId: Int, amount: Double, currency: String, description: String) async throws -> PurchaseOrder {
        guard let url = URL(string: "\(baseURL)/api/v1/purchase-orders") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body = CreatePORequest(supplierId: supplierId, amount: amount, currency: currency, description: description)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 else {
            throw APIError.serverError("Failed to create purchase order")
        }
        do {
            return try JSONDecoder().decode(PurchaseOrder.self, from: data)
        } catch {
            print("Decoding error: \(error)")
            throw APIError.serverError("Decode failed: \(error)")
        }
    }
    
    
    func transitionPurchaseOrder(poId: Int, action: String, reason: String? = nil) async throws -> PurchaseOrder {
        guard let url = URL(string: "\(baseURL)/api/v1/purchase-orders/\(poId)/transitions") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: String] = ["action": action]
        if let reason {
            body["reason"] = reason
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if let errorBody = try? JSONDecoder().decode([String: String].self, from: data),
               let detail = errorBody["detail"] {
                throw APIError.serverError(detail)
            }
            throw APIError.serverError("Transition failed with status \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(PurchaseOrder.self, from: data)
        } catch {
            print("Decoding error: \(error)")
            throw APIError.serverError("Response decode failed: \(error.localizedDescription)")
        }
    }

    func escalatePurchaseOrder(poId: Int, note: String) async throws -> PurchaseOrder {
        guard let url = URL(string: "\(baseURL)/api/v1/purchase-orders/\(poId)/escalate") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["note": note])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if let errorBody = try? JSONDecoder().decode([String: String].self, from: data),
               let detail = errorBody["detail"] {
                throw APIError.serverError(detail)
            }
            throw APIError.serverError("Escalate failed with status \(httpResponse.statusCode)")
        }
        return try JSONDecoder().decode(PurchaseOrder.self, from: data)
    }

    struct RequesterSupplierHistory: Codable {
        let blockedCount: Int
        let details: [TriggerReasonDetail]

        enum CodingKeys: String, CodingKey {
            case blockedCount = "blocked_count"
            case details
        }
    }

    func fetchRequesterSupplierHistory(poId: Int) async throws -> RequesterSupplierHistory {
        guard let url = URL(string: "\(baseURL)/api/v1/purchase-orders/\(poId)/requester-supplier-history") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.serverError("Failed to fetch requester/supplier history")
        }
        return try JSONDecoder().decode(RequesterSupplierHistory.self, from: data)
    }
    
    
    struct CurrentUser: Codable {
        let id: Int
        let email: String
        let role: String
        let team: String?
    }
    
    var currentUser: CurrentUser?

    func fetchCurrentUser() async throws {
        guard let url = URL(string: "\(baseURL)/api/v1/users/me") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.serverError("Failed to fetch current user")
        }
        self.currentUser = try JSONDecoder().decode(CurrentUser.self, from: data)
    }
    
    struct ExceptionRequest: Codable, Identifiable, Hashable {
        let id: Int
        let purchaseOrderId: Int
        let requestedById: Int
        let justification: String
        let urgency: String
        let expiryAt: String
        let status: String
        let decidedById: Int?
        let decidedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case purchaseOrderId = "purchase_order_id"
            case requestedById = "requested_by_id"
            case justification, urgency
            case expiryAt = "expiry_at"
            case status
            case decidedById = "decided_by_id"
            case decidedAt = "decided_at"
        }
    }

    func submitExceptionRequest(poId: Int, justification: String, urgency: String, expiryAt: String) async throws -> ExceptionRequest {
        guard let url = URL(string: "\(baseURL)/api/v1/exception-requests") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "purchase_order_id": poId,
            "justification": justification,
            "urgency": urgency,
            "expiry_at": expiryAt
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard httpResponse.statusCode == 201 else {
            if let errorBody = try? JSONDecoder().decode([String: String].self, from: data),
               let detail = errorBody["detail"] {
                throw APIError.serverError(detail)
            }
            throw APIError.serverError("Failed to submit exception request (status \(httpResponse.statusCode))")
        }
        return try JSONDecoder().decode(ExceptionRequest.self, from: data)
    }

    func fetchAuditLog(entityType: String? = nil, entityId: Int? = nil) async throws -> [AuditLogEntry] {
        var components = URLComponents(string: "\(baseURL)/api/v1/audit-log")!
        var queryItems: [URLQueryItem] = []
        if let entityType { queryItems.append(URLQueryItem(name: "entity_type", value: entityType)) }
        if let entityId { queryItems.append(URLQueryItem(name: "entity_id", value: String(entityId))) }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        var request = URLRequest(url: components.url!)
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.serverError("Failed to fetch audit log")
        }
        return try JSONDecoder().decode([AuditLogEntry].self, from: data)
    }
    
    
    struct DashboardData: Codable {
            let blockedCreationAttempts: Int
            let blockedCreationAttemptDetails: [BlockedAttemptDetail]
            let exceptionRequests: ExceptionCounts
            let posAffectedByStaleOrUnassessed: Int
            let riskTierDistribution: [String: Int]
            let riskTierAmountDistribution: [String: Double]
            let avgApprovalTimeByTier: [String: Double?]
            let pendingApprovalAging: AgingStats
            let pendingApprovalAgingByTeam: [TeamPendingAging]
            let escalatedApprovals: [EscalatedApprovalDetail]
            let exceptionDriftSignals: ExceptionDriftSignals

            enum CodingKeys: String, CodingKey {
                case blockedCreationAttempts = "blocked_creation_attempts"
                case blockedCreationAttemptDetails = "blocked_creation_attempt_details"
                case exceptionRequests = "exception_requests"
                case posAffectedByStaleOrUnassessed = "pos_affected_by_stale_or_unassessed"
                case riskTierDistribution = "risk_tier_distribution"
                case riskTierAmountDistribution = "risk_tier_amount_distribution"
                case avgApprovalTimeByTier = "avg_approval_time_by_tier"
                case pendingApprovalAging = "pending_approval_aging"
                case pendingApprovalAgingByTeam = "pending_approval_aging_by_team"
                case escalatedApprovals = "escalated_approvals"
                case exceptionDriftSignals = "exception_drift_signals"
            }
        }

    struct BlockedAttemptDetail: Codable, Identifiable {
                var id: String { "\(supplierId)-\(at)" }
                let supplierId: Int
                let supplierName: String
                let actorEmail: String
                let rationale: String
                let at: String

                enum CodingKeys: String, CodingKey {
                    case supplierId = "supplier_id"
                    case supplierName = "supplier_name"
                    case actorEmail = "actor_email"
                    case rationale, at
                }
            }

    struct EscalatedApprovalDetail: Codable, Identifiable {
        var id: String { "\(poId)-\(at)" }
        let poId: Int
        let description: String
        let requesterEmail: String
        let stepNumber: Int
        let note: String
        let actorEmail: String
        let actorRoleAtTime: String
        let at: String

        enum CodingKeys: String, CodingKey {
            case poId = "po_id"
            case description
            case requesterEmail = "requester_email"
            case stepNumber = "step_number"
            case note
            case actorEmail = "actor_email"
            case actorRoleAtTime = "actor_role_at_time"
            case at
        }
    }

    struct TeamPendingAging: Codable, Identifiable {
        var id: String { team }
        let team: String
        let pendingCount: Int
        let avgDaysPending: Double?
        let oldestPendingDays: Int?

        enum CodingKeys: String, CodingKey {
            case team
            case pendingCount = "pending_count"
            case avgDaysPending = "avg_days_pending"
            case oldestPendingDays = "oldest_pending_days"
        }
    }

        struct ExceptionCounts: Codable {
            let submitted: Int
            let approved: Int
            let rejected: Int
            let lapsed: Int
        }

        struct AgingStats: Codable {
            let avgDaysPending: Double?
            let oldestPendingDays: Int?

            enum CodingKeys: String, CodingKey {
                case avgDaysPending = "avg_days_pending"
                case oldestPendingDays = "oldest_pending_days"
            }
        }

        struct ExceptionDriftSignals: Codable {
            let windowDays: Int
            let topSuppliers: [SupplierExceptionSignal]
            let topRequesters: [RequesterExceptionSignal]
            let triggerReasonDistribution: [String: Int]
            let triggerReasonDetails: [TriggerReasonDetail]

            enum CodingKeys: String, CodingKey {
                case windowDays = "window_days"
                case topSuppliers = "top_suppliers"
                case topRequesters = "top_requesters"
                case triggerReasonDistribution = "trigger_reason_distribution"
                case triggerReasonDetails = "trigger_reason_details"
            }
        }

    enum AnyCodableValue: Codable {
        case string(String)
        case double(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let boolValue = try? container.decode(Bool.self) {
                self = .bool(boolValue)
            } else if let doubleValue = try? container.decode(Double.self) {
                self = .double(doubleValue)
            } else if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
            } else {
                self = .null
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }

        var displayString: String {
            switch self {
            case .string(let value): return value
            case .double(let value): return String(format: "%.1f", value)
            case .bool(let value): return value ? "Yes" : "No"
            case .null: return "—"
            }
        }
    }
    
    struct TriggerReasonDetail: Codable, Identifiable {
        var id: String { "\(poId)-\(at)" }
        let poId: Int
        let actionType: String
        let rationale: String
        let at: String
        let metadata: [String: AnyCodableValue]?

        enum CodingKeys: String, CodingKey {
            case poId = "po_id"
            case actionType = "action_type"
            case rationale, at, metadata
        }
    }

        struct ExceptionDetail: Codable {
            let poId: Int
            let justification: String
            let decidedAt: String?

            enum CodingKeys: String, CodingKey {
                case poId = "po_id"
                case justification
                case decidedAt = "decided_at"
            }
        }

        struct SupplierExceptionSignal: Codable, Identifiable {
            var id: Int { supplierId }
            let supplierId: Int
            let supplierName: String
            let count: Int
            let totalAmountEur: Double

            enum CodingKeys: String, CodingKey {
                case supplierId = "supplier_id"
                case supplierName = "supplier_name"
                case count
                case totalAmountEur = "total_amount_eur"
            }
        }

        struct RequesterExceptionSignal: Codable, Identifiable {
            var id: Int { requesterId }
            let requesterId: Int
            let requesterEmail: String
            let count: Int

            enum CodingKeys: String, CodingKey {
                case requesterId = "requester_id"
                case requesterEmail = "requester_email"
                case count
            }
        }

        func fetchDashboard() async throws -> DashboardData {
            guard let url = URL(string: "\(baseURL)/api/v1/dashboard") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch dashboard")
            }
            do {
                return try JSONDecoder().decode(DashboardData.self, from: data)
            } catch {
                print("Dashboard decoding error: \(error)")
                throw APIError.serverError("Dashboard decode failed: \(error.localizedDescription)")
            }
        }

        func fetchSupplierExceptionDetails(supplierId: Int) async throws -> [ExceptionDetail] {
            guard let url = URL(string: "\(baseURL)/api/v1/dashboard/supplier-exceptions/\(supplierId)") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch supplier exception details")
            }
            return try JSONDecoder().decode([ExceptionDetail].self, from: data)
        }

        func fetchRequesterExceptionDetails(requesterId: Int) async throws -> [ExceptionDetail] {
            guard let url = URL(string: "\(baseURL)/api/v1/dashboard/requester-exceptions/\(requesterId)") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch requester exception details")
            }
            return try JSONDecoder().decode([ExceptionDetail].self, from: data)
        }

        struct ApprovalTimeDetail: Codable, Identifiable {
            var id: Int { poId }
            let poId: Int
            let description: String
            let amount: String
            let currency: String
            let supplierName: String
            let daysToDecision: Double
            let decidedAt: String

            enum CodingKeys: String, CodingKey {
                case poId = "po_id"
                case description, amount, currency
                case supplierName = "supplier_name"
                case daysToDecision = "days_to_decision"
                case decidedAt = "decided_at"
            }
        }

        func fetchApprovalTimeDetails(tier: String) async throws -> [ApprovalTimeDetail] {
            guard let url = URL(string: "\(baseURL)/api/v1/dashboard/approval-time-details/\(tier)") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch approval time details")
            }
            return try JSONDecoder().decode([ApprovalTimeDetail].self, from: data)
        }

    struct Supplier: Codable, Identifiable {
            let id: Int
            let name: String
            let status: String
            let country: String?
            let category: String?
            let deliveryReliabilityScore: Double?
            let defectRate: Double?
            let esgRating: Double?
            let sanctionsFlag: Bool
            let computedRiskTier: String?
            let inherentRiskTier: String
            let performanceRiskTier: String?
            let complianceRiskTier: String?
            let needsReassessment: Bool
            let reassessmentNote: String?

            enum CodingKeys: String, CodingKey {
                case id, name, status, country, category
                case deliveryReliabilityScore = "delivery_reliability_score"
                case defectRate = "defect_rate"
                case esgRating = "esg_rating"
                case sanctionsFlag = "sanctions_flag"
                case computedRiskTier = "computed_risk_tier"
                case inherentRiskTier = "inherent_risk_tier"
                case performanceRiskTier = "performance_risk_tier"
                case complianceRiskTier = "compliance_risk_tier"
                case needsReassessment = "needs_reassessment"
                case reassessmentNote = "reassessment_note"
            }
        }

        func fetchSuppliers() async throws -> [Supplier] {
            guard let url = URL(string: "\(baseURL)/api/v1/suppliers") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch suppliers")
            }
            return try JSONDecoder().decode([Supplier].self, from: data)
        }

        func fetchSupplier(id: Int) async throws -> Supplier {
            guard let url = URL(string: "\(baseURL)/api/v1/suppliers/\(id)") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch supplier #\(id)")
            }
            return try JSONDecoder().decode(Supplier.self, from: data)
        }

        func updateSupplierReassessment(id: Int, needsReassessment: Bool, reassessmentNote: String?) async throws -> Supplier {
            guard let url = URL(string: "\(baseURL)/api/v1/suppliers/\(id)") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            var body: [String: Any] = ["needs_reassessment": needsReassessment]
            if let reassessmentNote {
                body["reassessment_note"] = reassessmentNote
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to update supplier #\(id)")
            }
            return try JSONDecoder().decode(Supplier.self, from: data)
        }

        struct RiskThresholdOverride: Codable {
            let esgComplianceFloor: Double?
            let esgElevatedMargin: Double?
            let updatedById: Int?
            let updatedAt: String

            enum CodingKeys: String, CodingKey {
                case esgComplianceFloor = "esg_compliance_floor"
                case esgElevatedMargin = "esg_elevated_margin"
                case updatedById = "updated_by_id"
                case updatedAt = "updated_at"
            }
        }

        func fetchRiskSettings() async throws -> RiskThresholdOverride {
            guard let url = URL(string: "\(baseURL)/api/v1/risk-settings") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch risk settings")
            }
            return try JSONDecoder().decode(RiskThresholdOverride.self, from: data)
        }

        func updateRiskSettings(esgComplianceFloor: Double?) async throws -> RiskThresholdOverride {
            guard let url = URL(string: "\(baseURL)/api/v1/risk-settings") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["esg_compliance_floor": esgComplianceFloor as Any])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to update risk settings")
            }
            return try JSONDecoder().decode(RiskThresholdOverride.self, from: data)
        }

        struct ExceptionRequestDetail: Codable, Identifiable {
            let id: Int
            let purchaseOrderId: Int
            let requestedById: Int
            let justification: String
            let urgency: String
            let expiryAt: String
            let status: String
            let decidedById: Int?
            let decidedAt: String?
            let poDescription: String
            let poAmount: String
            let poCurrency: String
            let supplierName: String
            let requesterEmail: String

            enum CodingKeys: String, CodingKey {
                case id
                case purchaseOrderId = "purchase_order_id"
                case requestedById = "requested_by_id"
                case justification, urgency
                case expiryAt = "expiry_at"
                case status
                case decidedById = "decided_by_id"
                case decidedAt = "decided_at"
                case poDescription = "po_description"
                case poAmount = "po_amount"
                case poCurrency = "po_currency"
                case supplierName = "supplier_name"
                case requesterEmail = "requester_email"
            }
        }

        func fetchPendingExceptions() async throws -> [ExceptionRequestDetail] {
            guard let url = URL(string: "\(baseURL)/api/v1/exception-requests?status=pending") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch pending exceptions")
            }
            return try JSONDecoder().decode([ExceptionRequestDetail].self, from: data)
        }

        func decideException(id: Int, decision: String, reason: String) async throws -> ExceptionRequestDetail {
            guard let url = URL(string: "\(baseURL)/api/v1/exception-requests/\(id)/decision") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(["decision": decision, "reason": reason])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                if let errorBody = try? JSONDecoder().decode([String: String].self, from: data),
                   let detail = errorBody["detail"] {
                    throw APIError.serverError(detail)
                }
                throw APIError.serverError("Decision failed with status \(httpResponse.statusCode)")
            }
            return try JSONDecoder().decode(ExceptionRequestDetail.self, from: data)
        }


    struct RequesterDashboardData: Codable {
            let myPurchaseOrders: [PurchaseOrder]
            let myControlStatusBreakdown: [String: Int]
            let myTriggerReasonBreakdown: [String: Int]
            let myTriggerReasonDetails: [TriggerReasonDetail]
            let avgApprovalTimeByTier: [String: Double?]

            enum CodingKeys: String, CodingKey {
                case myPurchaseOrders = "my_purchase_orders"
                case myControlStatusBreakdown = "my_control_status_breakdown"
                case myTriggerReasonBreakdown = "my_trigger_reason_breakdown"
                case myTriggerReasonDetails = "my_trigger_reason_details"
                case avgApprovalTimeByTier = "avg_approval_time_by_tier"
            }
        }

    struct ApproverDashboardData: Codable {
            let team: String?
            let pendingApprovals: [PurchaseOrder]
            let pendingApprovalAging: AgingStats
            let teamControlStatusBreakdown: [String: Int]
            let teamTriggerReasonBreakdown: [String: Int]
            let teamPurchaseOrders: [PurchaseOrder]
            let teamTriggerReasonDetails: [TriggerReasonDetail]

            enum CodingKeys: String, CodingKey {
                case team
                case pendingApprovals = "pending_approvals"
                case pendingApprovalAging = "pending_approval_aging"
                case teamControlStatusBreakdown = "team_control_status_breakdown"
                case teamTriggerReasonBreakdown = "team_trigger_reason_breakdown"
                case teamPurchaseOrders = "team_purchase_orders"
                case teamTriggerReasonDetails = "team_trigger_reason_details"
            }
        }

        func fetchRequesterDashboard() async throws -> RequesterDashboardData {
            guard let url = URL(string: "\(baseURL)/api/v1/dashboard") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch dashboard")
            }
            return try JSONDecoder().decode(RequesterDashboardData.self, from: data)
        }

        func fetchApproverDashboard() async throws -> ApproverDashboardData {
            guard let url = URL(string: "\(baseURL)/api/v1/dashboard") else {
                throw APIError.invalidResponse
            }
            var request = URLRequest(url: url)
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError("Failed to fetch dashboard")
            }
            return try JSONDecoder().decode(ApproverDashboardData.self, from: data)
        }
}

struct TokenResponse: Codable {
    let accessToken: String
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}

struct AuditLogEntry: Codable, Identifiable {
    let id: Int
    let entityType: String
    let entityId: Int
    let actionType: String
    let actorId: Int?
    let rationale: String
    let metadataJson: [String: APIClient.AnyCodableValue]?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case entityType = "entity_type"
        case entityId = "entity_id"
        case actionType = "action_type"
        case actorId = "actor_id"
        case rationale
        case metadataJson = "metadata_json"
        case createdAt = "created_at"
    }
}
