import SwiftUI

/// Web版と同じ2ステップのログイン画面:
/// ステップ1でログイン/新規登録を選び、ステップ2で入力する。
/// 新規登録時のみニックネームと役割を入力する。
struct LoginView: View {
    @EnvironmentObject var store: CloudStore

    enum Mode { case chooser, login, signup }
    @State private var mode: Mode = .chooser
    @State private var email = ""
    @State private var password = ""
    @State private var nicknameInput = ""
    @State private var role: MemberRole = .questioner
    @State private var companies: Set<String> = [Companies.all[0]]
    @State private var department = Departments.all[0]
    @State private var section = Departments.sections(for: Departments.all[0])[0]
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .chooser:
                    Section {
                        Text("ご利用にはアカウントが必要です。初めての方は「新規登録」、登録済みの方は「ログイン」を選んでください。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Section {
                        Button {
                            switchMode(.login)
                        } label: {
                            Text("ログイン")
                                .bold()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())

                        Button {
                            switchMode(.signup)
                        } label: {
                            Text("新規登録")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    .listRowSeparator(.hidden)

                case .login, .signup:
                    Section {
                        TextField("メールアドレス", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("パスワード", text: $password)
                            .textContentType(.password)
                        if mode == .signup {
                            TextField("ニックネーム", text: $nicknameInput)
                                .textContentType(.nickname)
                        }
                    }

                    if mode == .signup {
                        Section("役割") {
                            Picker("役割", selection: $role) {
                                Text("担当者(質問のみ)").tag(MemberRole.questioner)
                                Text("財務(BA)").tag(MemberRole.expert)
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }

                        Section("所属") {
                            // 所属会社は複数選択できる(兼務あり)
                            Menu {
                                ForEach(Companies.all, id: \.self) { c in
                                    Button {
                                        if companies.contains(c) {
                                            if companies.count > 1 { companies.remove(c) }
                                        } else {
                                            companies.insert(c)
                                        }
                                    } label: {
                                        if companies.contains(c) {
                                            Label(c, systemImage: "checkmark")
                                        } else {
                                            Text(c)
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text("所属会社").foregroundColor(.primary)
                                    Spacer()
                                    Text(Companies.all.filter { companies.contains($0) }
                                        .joined(separator: "/"))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .font(.footnote)
                                }
                            }
                            Picker("所属部署", selection: $department) {
                                ForEach(Departments.all, id: \.self) { dept in
                                    Text(dept).tag(dept)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: department) { dept in
                                section = Departments.sections(for: dept).first ?? ""
                            }
                            Picker("所属担当", selection: $section) {
                                ForEach(Departments.sections(for: department), id: \.self) { sec in
                                    Text(sec).tag(sec)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                    }

                    Section {
                        Button {
                            submit()
                        } label: {
                            HStack(spacing: 8) {
                                if busy { ProgressView().tint(.white) }
                                Text(mode == .signup ? "新規登録" : "ログイン").bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(busy)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())

                        Button {
                            switchMode(.chooser)
                        } label: {
                            Text("戻る")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .navigationTitle(mode == .signup ? "新規登録" : mode == .login ? "ログイン" : "💬 会計相談チャット")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.accentDark)
    }

    private func switchMode(_ m: Mode) {
        mode = m
        errorMessage = nil
    }

    private func submit() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "メールアドレスとパスワードを入力してください。"
            return
        }
        let nickname = nicknameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .signup, nickname.isEmpty {
            errorMessage = "ニックネームを入力してください。"
            return
        }
        errorMessage = nil
        busy = true
        Task {
            do {
                if mode == .signup {
                    try await store.signup(email: email, password: password, role: role,
                                           nickname: nickname,
                                           companies: Companies.all.filter { companies.contains($0) },
                                           department: department, section: section)
                } else {
                    try await store.login(email: email, password: password)
                }
            } catch {
                errorMessage = CloudStore.authErrorMessage(error)
            }
            busy = false
        }
    }
}
