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
    @State private var company = Companies.all[0]
    @State private var department = Departments.all[0]
    @State private var section = Departments.sections(for: Departments.all[0])[0]

    private func syncOrgDefaults() {
        if !store.orgCompanies.contains(company) { company = store.orgCompanies.first ?? "" }
        let depts = store.departments(for: company)
        if !depts.contains(department) { department = depts.first ?? "" }
        let secs = store.sections(company: company, department: department)
        if !secs.contains(section) { section = secs.first ?? "" }
    }
    @State private var position = Positions.all.last ?? "一般"
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
                            Picker("会社", selection: $company) {
                                ForEach(store.orgCompanies, id: \.self) { c in
                                    Text(c).tag(c)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: company) { c in
                                // 会社を変えたら、その会社の部署・担当に合わせ直す
                                department = store.departments(for: c).first ?? ""
                                section = store.sections(company: c, department: department).first ?? ""
                            }
                            Picker("部署", selection: $department) {
                                ForEach(store.departments(for: company), id: \.self) { dept in
                                    Text(dept).tag(dept)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: department) { dept in
                                section = store.sections(company: company, department: dept).first ?? ""
                            }
                            Picker("担当", selection: $section) {
                                ForEach(store.sections(company: company, department: department), id: \.self) { sec in
                                    Text(sec).tag(sec)
                                }
                            }
                            .pickerStyle(.menu)
                            Picker("役職", selection: $position) {
                                ForEach(Positions.all, id: \.self) { p in
                                    Text(p).tag(p)
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
            .onAppear { syncOrgDefaults() }
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
                                           companies: [company],
                                           department: department, section: section, position: position)
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
