import SwiftUI
import UniformTypeIdentifiers

struct AuditLogView: View {
    var onReturnToDashboard: (() -> Void)? = nil
    @State private var entries: [AuditLogEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var selectedEntityTypes: Set<String> = []
    @State private var selectedActionTypes: Set<String> = []
    @State private var selectedDateRange: AuditDateRange = .allTime
    @State private var searchText: String = ""

    @State private var drillDownContext: (entityType: String, entityId: Int)? = nil

    // Sheets for opening the actual entity, not just its log entries
    @State private var openedPO: PurchaseOrder? = nil
    @State private var openedExceptionSummary: ExceptionSummary? = nil
    @State private var isOpeningDetail = false

    @State private var showingExporter = false
    @State private var exportDocument = CSVDocument(text: "")

    private let entityTypes = ["purchase_order", "supplier", "exception_request", "user"]

    private var availableActionTypes: [String] {
        Set(entries.map { $0.actionType }).sorted()
    }

    private var filteredEntries: [AuditLogEntry] {
        var result = entries
        if !selectedEntityTypes.isEmpty {
            result = result.filter { selectedEntityTypes.contains($0.entityType) }
        }
        if !selectedActionTypes.isEmpty {
            result = result.filter { selectedActionTypes.contains($0.actionType) }
        }
        if let cutoff = selectedDateRange.cutoffDate {
            result = result.filter { entry in
                guard let date = entry.createdAt.asDate else { return true }
                return date >= cutoff
            }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.rationale.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    // Groups by calendar day without reordering entries — every entry stays
    // individually visible (no aggregation of same-type events into a single
    // row), only clustered under a day heading so the feed reads as "what
    // happened on which day" instead of a flat, unordered dump.
    private var groupedEntries: [(day: String, entries: [AuditLogEntry])] {
        var order: [String] = []
        var buckets: [String: [AuditLogEntry]] = [:]
        for entry in filteredEntries {
            let day = entry.createdAt.asDayGroupLabel
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(entry)
        }
        return order.map { (day: $0, entries: buckets[$0] ?? []) }
    }

    // Count reflects the full loaded log (not the current entity/action
    // filters) — this is a standing control assertion, not a view of
    // whatever the user happens to be browsing right now.
    private var selfApprovalBlockedCount: Int {
        entries.filter { $0.actionType == "self_approval_blocked" }.count
    }

    var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    if let context = drillDownContext {
                        drillDownBanner(context)
                    }

                complianceStrip
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                HStack(spacing: 6) {
                    ForEach(entityTypes, id: \.self) { type in
                        entityChip(type)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .disabled(drillDownContext != nil)

                VStack(spacing: 8) {
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
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .cornerRadius(6)

                    HStack {
                        Text("Filter by:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Menu {
                            ForEach(availableActionTypes, id: \.self) { type in
                                Button {
                                    toggle(type, in: &selectedActionTypes)
                                } label: {
                                    if selectedActionTypes.contains(type) {
                                        Label(label(for: type), systemImage: "checkmark")
                                    } else {
                                        Text(label(for: type))
                                    }
                                }
                            }
                        } label: {
                            Label(actionTypeMenuTitle, systemImage: "line.3.horizontal.decrease.circle")
                        }

                        Menu {
                            ForEach(AuditDateRange.allCases) { range in
                                Button {
                                    selectedDateRange = range
                                } label: {
                                    if selectedDateRange == range {
                                        Label(range.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(range.rawValue)
                                    }
                                }
                            }
                        } label: {
                            Label(selectedDateRange.rawValue, systemImage: "calendar")
                        }

                        Spacer()

                        if !selectedEntityTypes.isEmpty || !selectedActionTypes.isEmpty || selectedDateRange != .allTime {
                            Button("Clear All") {
                                selectedEntityTypes = []
                                selectedActionTypes = []
                                selectedDateRange = .allTime
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .disabled(drillDownContext != nil)

                List {
                    ForEach(groupedEntries, id: \.day) { group in
                        Section(header: Text(group.day)) {
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                entryRow(entry, isLast: index == group.entries.count - 1)
                            }
                        }
                    }
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
                                ToolbarItemGroup {
                                    if onReturnToDashboard != nil {
                                        Button {
                                            onReturnToDashboard?()
                                        } label: {
                                            Label("Dashboard", systemImage: "chevron.left")
                                        }
                                    }
                                    Button {
                                        exportDocument = CSVDocument(text: buildCSV())
                                        showingExporter = true
                                    } label: {
                                        Label("Export CSV", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        Task { await load() }
                                    } label: {
                                        Label("Refresh", systemImage: "arrow.clockwise")
                                    }
                                    Button(role: .destructive) {
                                        APIClient.shared.logout()
                                    } label: {
                                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                                    }
                                }
                            }
            .task { await load() }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "audit_trail_export.csv"
            ) { result in
                if case .failure(let error) = result {
                    errorMessage = "Export failed: \(error.localizedDescription)"
                }
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

    // MARK: - Compliance strip

    // Puts two facts an auditor needs on-screen: the audit_log is
    // insert-only at the database level (not just an app-layer promise),
    // and how many self-approval attempts the segregation-of-duties control
    // has actually blocked. Both are backed by real, verifiable mechanisms —
    // not decorative copy.
    private var complianceStrip: some View {
        HStack(spacing: 16) {
            Label("Insert-only, tamper-evident", systemImage: "lock.shield.fill")
                .help("Audit records cannot be modified or deleted after creation — enforced by a database-level trigger (audit_log_no_update), not just application code.")

            Label(
                "\(selfApprovalBlockedCount) self-approval attempt\(selfApprovalBlockedCount == 1 ? "" : "s") blocked",
                systemImage: "person.crop.circle.badge.xmark"
            )
            .help("Segregation of duties: a user can never approve or reject their own request — enforced at write time. This counts blocked attempts across the full audit log, not just the current filter.")

            Spacer()
        }
        .font(.caption.weight(.medium))
        .foregroundColor(.secondary)
    }

    // MARK: - Filter chips

    private func entityChip(_ type: String) -> some View {
        let isSelected = selectedEntityTypes.contains(type)
        return Button {
            toggle(type, in: &selectedEntityTypes)
        } label: {
            Text(label(for: type))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.blue.opacity(0.18) : Color.gray.opacity(0.1))
                .foregroundColor(isSelected ? .blue : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ value: String, in set: inout Set<String>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    private var actionTypeMenuTitle: String {
        switch selectedActionTypes.count {
        case 0: return "Action Type"
        case 1: return label(for: selectedActionTypes.first!)
        default: return "\(selectedActionTypes.count) Action Types"
        }
    }

    // MARK: - Drill-down banner

    @ViewBuilder
    private func drillDownBanner(_ context: (entityType: String, entityId: Int)) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(.secondary)
            Text("Showing full history for \(label(for: context.entityType)) #\(context.entityId)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                drillDownContext = nil
                Task { await load() }
            } label: {
                Label("Clear Filter", systemImage: "xmark.circle.fill")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.blue.opacity(0.15))
    }

    // MARK: - Row

    // Reuses the icon-in-circle + connecting-line timeline language from
    // PurchaseOrderDetailView's approval steps, so "what happened" (audit
    // trail) and "what's happening to this PO" (approval timeline) read as
    // the same visual system rather than two unrelated components.
    @ViewBuilder
    private func entryRow(_ entry: AuditLogEntry, isLast: Bool) -> some View {
        let (icon, color) = iconInfo(for: entry)

        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(color)
                }
                if !isLast {
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 2)
                        .frame(minHeight: 24)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(headline(for: entry))
                    .font(.headline)
                Text(summary(for: entry))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Text(actorLine(for: entry))
                    Spacer()
                    Text(entry.createdAt.asFormattedDateTime)
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
            .padding(.bottom, isLast ? 0 : 16)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Icons

    private func iconInfo(for entry: AuditLogEntry) -> (systemImage: String, color: Color) {
        switch entry.actionType {
        case "po_status_transition":
            if let metadata = entry.metadataJson, let status = metadata["control_status"] {
                let risk = RiskStatus(rawValue: status.displayString)
                return (risk.icon, risk.color)
            }
            return ("arrow.triangle.2.circlepath", .secondary)

        case "risk_trigger_compliance_floor", "risk_trigger_stale",
             "risk_trigger_incomplete_or_unassessed", "po_creation_blocked":
            return ("shield.slash.fill", .red)

        case "self_approval_blocked":
            return ("hand.raised.fill", .red)

        case "exception_submitted":
            return ("exclamationmark.triangle.fill", .orange)

        case "exception_approved", "po_approved_with_exception":
            return ("checkmark.seal.fill", .purple)

        case "exception_rejected":
            return ("xmark.seal.fill", .red)

        case "exception_lapsed":
            return ("clock.fill", .secondary)

        case "supplier_status_change":
            return ("building.2.fill", .gray)

        case "role_elevation":
            return ("person.2.fill", .gray)

        default:
            return ("doc.text.fill", .secondary)
        }
    }

    // MARK: - Actions

    private func drillIntoLog(_ entry: AuditLogEntry) {
        drillDownContext = (entry.entityType, entry.entityId)
        selectedEntityTypes = []
        selectedActionTypes = []
        selectedDateRange = .allTime
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
    private func exceptionSummarySheet(_ exceptionSummary: ExceptionSummary) -> some View {
        NavigationStack {
            List {
                Section("Exception Request #\(exceptionSummary.id)") {
                    Text("No dedicated read endpoint exists for exception requests. This summary is reconstructed from its own audit trail entries below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section("History") {
                    ForEach(exceptionSummary.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(headline(for: entry)).font(.headline)
                            Text(summary(for: entry)).font(.subheadline)
                            Text(entry.createdAt.asFormattedDateTime).font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Exception #\(exceptionSummary.id)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { openedExceptionSummary = nil }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    // MARK: - CSV export

    private func buildCSV() -> String {
        func esc(_ value: String) -> String {
            "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        var lines = ["id,entity_type,entity_id,action_type,actor,summary,created_at_utc"]
        for entry in filteredEntries {
            let row = [
                String(entry.id),
                esc(entry.entityType),
                String(entry.entityId),
                esc(entry.actionType),
                esc(actorLine(for: entry)),
                esc(summary(for: entry)),
                esc(entry.createdAt.asFormattedDateTime),
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actor line

    /// Prefers the permission snapshot captured at decision time
    /// (actor_email + actor_role_at_time in metadata) over a live user-ID
    /// lookup — the latter would silently reflect the actor's *current*
    /// role, which can drift from what they held when they actually made
    /// the decision.
    private func actorLine(for entry: AuditLogEntry) -> String {
        if let metadata = entry.metadataJson,
           let email = metadata["actor_email"], let role = metadata["actor_role_at_time"] {
            return "\(email.displayString) — \(label(for: role.displayString)) at the time"
        }
        if let actorId = entry.actorId {
            return "Actor: user #\(actorId)"
        }
        return "System action"
    }

    // MARK: - Summaries

    /// Falls back to the raw rationale when metadata is missing or the
    /// action_type has no structured renderer below (same pattern as
    /// TriggerReasonDetailListView.summary(for:)).
    private func summary(for entry: AuditLogEntry) -> String {
        guard let metadata = entry.metadataJson else {
            return entry.rationale
        }

        switch entry.actionType {
        case "po_status_transition":
            if let decision = metadata["decision"], let stepNumber = metadata["step_number"] {
                return "Step \(stepNumber.displayString) \(decision.displayString)d"
            }
            guard let status = metadata["control_status"], let validity = metadata["validity"] else {
                return entry.rationale
            }
            var tierPhrase = ""
            if case .string(let tierValue)? = metadata["tier"] {
                tierPhrase = "\(tierValue.capitalized) risk, "
            }
            return "Submitted and routed as \(status.displayString.capitalized) "
                + "(\(tierPhrase)\(validity.displayString) assessment)"

        case "risk_trigger_compliance_floor":
            guard let esg = metadata["esg_rating"],
                  case .bool(let sanctioned)? = metadata["sanctions_flag"] else {
                return entry.rationale
            }
            let sanctionsPhrase = sanctioned ? "sanctions flag raised" : "no sanctions flag"
            return "ESG rating \(esg.displayString) below compliance floor, \(sanctionsPhrase)"

        case "exception_submitted":
            guard let poId = metadata["po_id"], let urgency = metadata["urgency"] else {
                return entry.rationale
            }
            return "Exception requested for PO #\(poId.displayString) (\(urgency.displayString.capitalized) urgency)"

        case "po_approved_with_exception":
            guard let poId = metadata["po_id"], let exceptionRequestId = metadata["exception_request_id"] else {
                return entry.rationale
            }
            return "PO #\(poId.displayString) approved via exception (request #\(exceptionRequestId.displayString))"

        case "po_creation_blocked":
            guard let supplierName = metadata["supplier_name"] else {
                return entry.rationale
            }
            return "Attempted PO creation against blocked supplier \(supplierName.displayString)"

        case "risk_trigger_incomplete_or_unassessed":
            guard let validity = metadata["validity"] else {
                return entry.rationale
            }
            return "Blocked: supplier risk assessment is \(validity.displayString) (missing or never completed)"

        case "risk_trigger_stale":
            guard let ageDays = metadata["age_days"], let windowDays = metadata["staleness_window_days"] else {
                return entry.rationale
            }
            var tierPhrase = ""
            if let lastTier = metadata["last_computed_tier"] {
                tierPhrase = ", last computed tier \(lastTier.displayString.capitalized)"
            }
            return "Blocked: risk assessment stale (\(ageDays.displayString)d old, "
                + "staleness window \(windowDays.displayString)d\(tierPhrase))"

        case "self_approval_blocked":
            guard let email = metadata["actor_email"], let role = metadata["actor_role_at_time"] else {
                return entry.rationale
            }
            return "\(email.displayString) (\(role.displayString)) attempted to decide their own "
                + "request — blocked by segregation-of-duties control"

        default:
            return entry.rationale
        }
    }

    // MARK: - Headlines

    /// The row's title: leads with "what happened" (entity + outcome) rather
    /// than a bare category name, so the headline alone answers the question
    /// — summary(for:) below it adds supporting detail for those who want it.
    private func headline(for entry: AuditLogEntry) -> String {
        let poRef = entry.entityType == "purchase_order" ? "PO #\(entry.entityId)" : label(for: entry.actionType)

        switch entry.actionType {
        case "po_status_transition":
            if let metadata = entry.metadataJson,
               let decision = metadata["decision"], let stepNumber = metadata["step_number"] {
                return "\(poRef) step \(stepNumber.displayString) \(decision.displayString)d"
            }
            if let metadata = entry.metadataJson, let status = metadata["control_status"] {
                return "\(poRef) submitted, routed as \(status.displayString.capitalized)"
            }
            return "\(poRef) submitted"

        case "risk_trigger_compliance_floor":
            return "\(poRef) blocked, compliance floor failed"

        case "risk_trigger_stale":
            return "\(poRef) blocked, risk assessment stale"

        case "risk_trigger_incomplete_or_unassessed":
            return "\(poRef) blocked, risk assessment incomplete"

        case "po_creation_blocked":
            return "PO creation blocked"

        case "self_approval_blocked":
            if let metadata = entry.metadataJson, let poId = metadata["po_id"] {
                return "Self-approval blocked for PO #\(poId.displayString)"
            }
            return "Self-approval blocked"

        case "exception_submitted":
            if let metadata = entry.metadataJson, let poId = metadata["po_id"] {
                return "Exception requested for PO #\(poId.displayString)"
            }
            return "Exception requested"

        case "po_approved_with_exception":
            return "\(poRef) approved with exception"

        default:
            return label(for: entry.actionType)
        }
    }

    // MARK: - Labels

    private func label(for type: String) -> String {
            if type == "po_status_transition" {
                return "Approval Timeline"
            }
            if type == "po_approved_with_exception" {
                return "PO Approved With Exception"
            }
            if type == "po_creation_blocked" {
                return "PO Creation Blocked"
            }
            if type == "self_approval_blocked" {
                return "Self-Approval Blocked"
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

enum AuditDateRange: String, CaseIterable, Identifiable {
    case allTime = "All Time"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case last90Days = "Last 90 Days"

    var id: String { rawValue }

    var cutoffDate: Date? {
        let days: Int
        switch self {
        case .allTime: return nil
        case .last7Days: days = 7
        case .last30Days: days = 30
        case .last90Days: days = 90
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
