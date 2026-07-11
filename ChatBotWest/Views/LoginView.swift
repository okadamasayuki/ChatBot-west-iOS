import SwiftUI
import UIKit

/// Web版と同じ2ステップのログイン画面:
/// ステップ1でログイン/新規登録を選び、ステップ2で入力する。
/// 新規登録時のみニックネームと役割を入力する。
struct LoginView: View {
    @EnvironmentObject var store: CloudStore

    enum Mode { case chooser, login, signup }
    @State private var mode: Mode = .chooser
    @State private var email = ""
    // デモ用: サンプルアカウント共通のパスワードを最初から入れておく
    @State private var password = "00000000"
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
                        if mode == .login {
                            // デフォルトの zaimu@gmail.com を入れ、カーソルを「u」の直後に置く
                            CursorEmailField(text: $email,
                                             placeholder: "メールアドレス",
                                             cursorIndex: 5,
                                             defaultText: "zaimu@gmail.com")
                        } else {
                            TextField("メールアドレス", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        SecureField("パスワード", text: $password)
                            .textContentType(.password)
                        if mode == .signup {
                            TextField("氏名", text: $nicknameInput)
                                .textContentType(.nickname)
                        }
                    }

                    if mode == .signup {
                        Section("役割") {
                            Picker("役割", selection: $role) {
                                Text("質問").tag(MemberRole.questioner)
                                Text("回答").tag(MemberRole.expert)
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
        // ログインはデモ用の共通アドレス・パスワードを初期入力、新規登録は空にする
        email = (m == .login) ? "zaimu@gmail.com" : ""
        password = (m == .login) ? "00000000" : ""
    }

    private func submit() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "メールアドレスとパスワードを入力してください。"
            return
        }
        let nickname = nicknameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .signup, nickname.isEmpty {
            errorMessage = "氏名を入力してください。"
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


/// カーソル位置を指定できるメール入力欄(ログイン画面用)。
/// 表示時に自動でフォーカスし、デフォルト文字列のときはカーソルを指定位置に置く
struct CursorEmailField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var cursorIndex: Int
    var defaultText: String

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.keyboardType = .emailAddress
        tf.textContentType = .username
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 表示されたら自動でフォーカス(カーソルが置かれた状態にする)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak tf] in
            tf?.becomeFirstResponder()
        }
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        if tf.text != text { tf.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CursorEmailField
        init(_ parent: CursorEmailField) { self.parent = parent }

        @objc func changed(_ tf: UITextField) {
            parent.text = tf.text ?? ""
        }

        func textFieldDidBeginEditing(_ tf: UITextField) {
            // デフォルト文字列のままなら「u」の直後にカーソルを置く
            guard tf.text == parent.defaultText,
                  let pos = tf.position(from: tf.beginningOfDocument, offset: parent.cursorIndex) else { return }
            DispatchQueue.main.async {
                tf.selectedTextRange = tf.textRange(from: pos, to: pos)
            }
        }
    }
}
