import SwiftUI

struct AuditLogView: View {
    var onReturnToDashboard: (() -> Void)? = nil
    @State private var entries: [AuditLogEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var filterEntityType: String = "all"
    @State private var filterActionType: String = "all"
    @State private var searchText: String = ""

    @State private var drillDownContext: (entityType: String, entityId: Int)? = nil

    // Sheets for opening the actual entity, not just its log entries
    @State private var openedPO: PurchaseOrder? = nil
    @State private var openedExceptionSummary: ExceptionSummary? = nil
    @State private var isOpeningDetail = false

    private let entityTypes = ["all", "purchase_order", "supplier", "exception_request", "user"]

    private var availableActionTypes: [String] {
        let types = Set(entries.map { $0.actionType })
        return ["all"] + types.sorted()
    }

    private var filteredEntries: [AuditLogEntry] {
        var result = entries
        if filterEntityType != "all" {
            result = result.filter { $0.entityType == filterEntityType }
        }
        if filterActionType != "all" {
            result = result.filter { $0.actionType == filterActionType }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.rationale.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    if onReturnToDashboard != nil {
                        backToDashboardBar
                    }

                    if let context = drillDownContext {
                        drillDownBanner(context)
                    }

                Picker("Filter", selection: $filterEntityType) {
                    ForEach(entityTypes, id: \.self) { type in
                        Text(type == "all" ? "All" : label(for: type)).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top], 8)
                .disabled(drillDownContext != nil)

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search rationale…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Menu {
                        ForEach(availableActionTypes, id: \.self) { type in
                            Button {
                                filterActionType = type
                            } label: {
                                if filterActionType == type {
                                    Label(type == "all" ? "All Actions" : label(for: type), systemImage: "checkmark")
                                } else {
                                    Text(type == "all" ? "All Actions" : label(for: type))
                                }
                            }
                        }
                    } label: {
                        Label(filterActionType == "all" ? "Action" : label(for: filterActionType), systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.3))
                .cornerRadius(6)
                .padding(.horizontal, 8)
                .padding(.top, 6)

                List(filteredEntries) { entry in
                    entryRow(entry)
                }
                .listStyle(.inset)
                .overlay {
                    if isLoading || isOpeningDetail { ProgressView() }
                    if !isLoading && filteredEntries.isEmpty {
                        ContentUnavailableView(
                            "No matching entries",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Try a different filter or search term.")
                        )
                    }
                }
            }
            .navigationTitle("Audit Trail")
                            .toolbar {
                                ToolbarItem {
                                    Button("Refresh") {
                                        Task { await load() }
                                    }
                                }
                            }
            .task { await load() }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $openedPO) { po in
                NavigationStack {
                    PurchaseOrderDetailView(po: po)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { openedPO = nil }
                            }
                        }
                }
                .frame(minWidth: 480, minHeight: 420)
            }
            .sheet(item: $openedExceptionSummary) { summary in
                exceptionSummarySheet(summary)
            }
        }
    }
    
    // MARK: - Navigation

        private var backToDashboardBar: some View {
            HStack {
                Button {
                    onReturnToDashboard?()
                } label: {
                    Label("Back to Dashboard", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                Spacer()
            }
            .padding(10)
            .background(Color.gray.opacity(0.08))
        }
    

    // MARK: - Drill-down banner

    @ViewBuilder
    private func drillDownBanner(_ context: (entityType: String, entityId: Int)) -> some View {
        HStack {
            Image(systemName: "arrow.turn.up.left")
            Text("Full history — \(label(for: context.entityType)) #\(context.entityId)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Back to All Entries") {
                drillDownContext = nil
                Task { await load() }
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.15))
    }

    // MARK: - Row

    @ViewBuilder
    private func entryRow(_ entry: AuditLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label(for: entry.actionType))
                    .font(.headline)
                Spacer()
            }
            Text(entry.rationale)
                .font(.subheadline)

            HStack {
                if let actorId = entry.actorId {
                    Text("Actor: user #\(actorId)")
                } else {
                    Text("System action")
                }
                Spacer()
                Text(entry.createdAt)
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            // Two distinct, clearly-labeled action buttons — not a single
            // ambiguous text link.
            HStack(spacing: 8) {
                Button {
                    drillIntoLog(entry)
                } label: {
                    Label("View All Log Entries", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if entry.entityType == "purchase_order" {
                    Button {
                        openPODetail(id: entry.entityId)
                    } label: {
                        Label("Open PO #\(entry.entityId)", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if entry.entityType == "exception_request" {
                    Button {
                        openExceptionSummary(entry: entry)
                    } label: {
                        Label("Open Exception #\(entry.entityId)", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func drillIntoLog(_ entry: AuditLogEntry) {
        drillDownContext = (entry.entityType, entry.entityId)
        filterEntityType = "all"
        filterActionType = "all"
        searchText = ""
        Task { await load() }
    }

    private func openPODetail(id: Int) {
        Task {
            isOpeningDetail = true
            do {
                openedPO = try await APIClient.shared.fetchPurchaseOrder(id: id)
            } catch {
                errorMessage = "Failed to open PO #\(id): \(error.localizedDescription)"
            }
            isOpeningDetail = false
        }
    }

    // No GET /exception-requests/{id} exists on the backend (only POST create
    // and POST decision) — rather than fabricate an endpoint that isn't
    // there, this reconstructs a read-only summary from the audit log
    // entries already available for this exception_request id.
    private func openExceptionSummary(entry: AuditLogEntry) {
        Task {
            isOpeningDetail = true
            do {
                let related = try await APIClient.shared.fetchAuditLog(
                    entityType: "exception_request", entityId: entry.entityId
                )
                openedExceptionSummary = ExceptionSummary(id: entry.entityId, entries: related)
            } catch {
                errorMessage = "Failed to open exception #\(entry.entityId): \(error.localizedDescription)"
            }
            isOpeningDetail = false
        }
    }

    @ViewBuilder
    private func exceptionSummarySheet(_ summary: ExceptionSummary) -> some View {
        NavigationStack {
            List {
                Section("Exception Request #\(summary.id)") {
                    Text("No dedicated read endpoint exists for exception requests — this summary is reconstructed from its own audit trail entries below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section("History") {
                    ForEach(summary.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(for: entry.actionType)).font(.headline)
                            Text(entry.rationale).font(.subheadline)
                            Text(entry.createdAt).font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Exception #\(summary.id)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { openedExceptionSummary = nil }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    // MARK: - Labels

    private func label(for type: String) -> String {
            if type == "po_status_transition" {
                return "Approval Timeline"
            }
            if type == "po_approved_with_exception" {
                return "PO Approved With Exception"
            }
            return type.replacingOccurrences(of: "_", with: " ").capitalized
        }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            if let context = drillDownContext {
                entries = try await APIClient.shared.fetchAuditLog(
                    entityType: context.entityType, entityId: context.entityId
                )
            } else {
                entries = try await APIClient.shared.fetchAuditLog()
            }
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

struct ExceptionSummary: Identifiable {
    let id: Int
    let entries: [AuditLogEntry]
}
