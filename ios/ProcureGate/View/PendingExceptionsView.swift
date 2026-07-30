import SwiftUI

enum PendingExceptionDecision: Equatable {
    case approve, reject
}

struct PendingExceptionsView: View {
    var onReturnToDashboard: (() -> Void)? = nil
    @State private var exceptions: [APIClient.ExceptionRequestDetail] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var decidingId: Int?
    @State private var pendingDecision: PendingExceptionDecision?
    @State private var noteText = ""

    private var currentUserId: Int? {
        APIClient.shared.currentUser?.id
    }

    var body: some View {
        NavigationStack {
            List(exceptions) { exception in
                exceptionRow(exception)
            }
            .listStyle(.inset)
            .navigationTitle("Pending Exceptions")
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
            .overlay {
                if isLoading { ProgressView() }
                if !isLoading && exceptions.isEmpty {
                    ContentUnavailableView(
                        "No pending exceptions",
                        systemImage: "checkmark.seal",
                        description: Text("Nothing is waiting on a decision right now.")
                    )
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func exceptionRow(_ exception: APIClient.ExceptionRequestDetail) -> some View {
        let isOwnRequest = exception.requestedById == currentUserId

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PO #\(exception.purchaseOrderId): \(exception.poDescription)")
                    .font(.headline)
                Spacer()
                Text("\(exception.poAmount) \(exception.poCurrency)")
                    .font(.subheadline.weight(.semibold))
            }
            Text(exception.supplierName)
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Text("Requested by \(exception.requesterEmail)")
                Text("·")
                Text("\(exception.urgency.capitalized) urgency")
                Spacer()
                Text("Expires \(exception.expiryAt.asFormattedDateTime)")
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            Text(exception.justification)
                .font(.subheadline)
                .padding(.vertical, 2)

            // Told up front instead of discovered by clicking Approve and
            // getting a 403 back — the backend already enforces this
            // (FR-013), this is just saying it before the click instead of
            // after.
            if isOwnRequest {
                Label(
                    "This is your own request — segregation of duties means you can't decide it. Ask another procurement lead.",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundColor(.orange)
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            } else if decidingId == exception.id {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pendingDecision == .approve ? "Reason for approving (required)" : "Reason for rejecting (required)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    TextField("Explain your decision…", text: $noteText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                        .padding(8)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(8)
                    HStack {
                        Button("Cancel") {
                            decidingId = nil
                            pendingDecision = nil
                            noteText = ""
                        }
                        Spacer()
                        Button(pendingDecision == .approve ? "Confirm Approve" : "Confirm Reject") {
                            Task { await confirmDecision(exception) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(pendingDecision == .approve ? .green : .red)
                        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        decidingId = exception.id
                        pendingDecision = .approve
                        noteText = ""
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)

                    Button {
                        decidingId = exception.id
                        pendingDecision = .reject
                        noteText = ""
                    } label: {
                        Label("Reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            exceptions = try await APIClient.shared.fetchPendingExceptions()
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func confirmDecision(_ exception: APIClient.ExceptionRequestDetail) async {
        guard let pendingDecision else { return }
        let reason = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await APIClient.shared.decideException(
                id: exception.id,
                decision: pendingDecision == .approve ? "approved" : "rejected",
                reason: reason
            )
            exceptions.removeAll { $0.id == exception.id }
        } catch {
            errorMessage = "Failed to decide: \(error.localizedDescription)"
        }
        decidingId = nil
        self.pendingDecision = nil
        noteText = ""
    }
}
