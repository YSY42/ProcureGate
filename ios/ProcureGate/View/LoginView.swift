//
//  LoginView.swift
//  ProcureGate
//
//  Created by Naomi Yang on 25/07/2026.
//

import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loginSucceeded = false

    var body: some View {
        ZStack {
            Color.gray.opacity(0.03)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image("ProcureGateMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                    }

                    Text("ProcureGate")
                        .font(.system(size: 40, weight: .bold))
                    Text("Purchase order approvals, routed by risk.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EMAIL")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.secondary)
                        TextField("you@company.com", text: $email)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .padding(14)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(8)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("PASSWORD")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.secondary)
                        SecureField("••••••••", text: $password)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .padding(14)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(8)
                    }

                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorMessage)
                        }
                        .font(.subheadline)
                        .foregroundColor(.red)
                    }

                    if loginSucceeded {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Login succeeded")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.green)
                    }

                    Button {
                        Task {
                            await performLogin()
                        }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Log In")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(email.isEmpty || password.isEmpty || isLoading)
                    .padding(.top, 4)
                }
            }
            .padding(36)
            .frame(maxWidth: 400)
            .background(Color.gray.opacity(0.06))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func performLogin() async {
        isLoading = true
        errorMessage = nil
        loginSucceeded = false

        do {
            try await APIClient.shared.login(email: email, password: password)
            loginSucceeded = true
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }

        isLoading = false
    }
}

#Preview {
    LoginView()
}
