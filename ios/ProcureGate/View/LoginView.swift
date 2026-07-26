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
        VStack(spacing: 16) {
            Text("ProcureGate")
                .font(.largeTitle)
                .bold()

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            if loginSucceeded {
                Text("Login succeeded ✅")
                    .foregroundColor(.green)
            }

            Button {
                Task {
                    await performLogin()
                }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Text("Log In")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || isLoading)
        }
        .padding()
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
