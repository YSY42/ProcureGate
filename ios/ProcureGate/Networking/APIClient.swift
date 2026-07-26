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
    
    
    func transitionPurchaseOrder(poId: Int, action: String) async throws -> PurchaseOrder {
        guard let url = URL(string: "\(baseURL)/api/v1/purchase-orders/\(poId)/transitions") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body = ["action": action]
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
            let exceptionRequests: ExceptionCounts
            let posAffectedByStaleOrUnassessed: Int
            let riskTierDistribution: [String: Int]
            let avgApprovalTimeByTier: [String: Double?]
            let pendingApprovalAging: AgingStats
            let exceptionDriftSignals: ExceptionDriftSignals

            enum CodingKeys: String, CodingKey {
                case blockedCreationAttempts = "blocked_creation_attempts"
                case exceptionRequests = "exception_requests"
                case posAffectedByStaleOrUnassessed = "pos_affected_by_stale_or_unassessed"
                case riskTierDistribution = "risk_tier_distribution"
                case avgApprovalTimeByTier = "avg_approval_time_by_tier"
                case pendingApprovalAging = "pending_approval_aging"
                case exceptionDriftSignals = "exception_drift_signals"
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

            enum CodingKeys: String, CodingKey {
                case windowDays = "window_days"
                case topSuppliers = "top_suppliers"
                case topRequesters = "top_requesters"
                case triggerReasonDistribution = "trigger_reason_distribution"
            }
        }

        struct SupplierExceptionSignal: Codable, Identifiable {
            var id: Int { supplierId }
            let supplierId: Int
            let supplierName: String
            let count: Int

            enum CodingKeys: String, CodingKey {
                case supplierId = "supplier_id"
                case supplierName = "supplier_name"
                case count
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
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case entityType = "entity_type"
        case entityId = "entity_id"
        case actionType = "action_type"
        case actorId = "actor_id"
        case rationale
        case createdAt = "created_at"
    }
}
