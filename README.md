# 会計相談チャット (iOS)

[chatbot-west](https://github.com/okadamasayuki/chatbot-west)(Web版)の iOS ネイティブ版です。SwiftUI 製で、**Web版と同じ Firebase(Auth / Firestore / Functions)に接続**するため、相談・案件・社内ルール・マニュアルは Web版とリアルタイムで共有されます。

## 機能(Web版と同等)

- 💬 **LINE風チャットUI + トークルーム** — 相談を質問ごとのルームに分けて管理。「＋ 新規」で作成、スワイプで削除(自分の相談のみ)
- 🔀 **並び替え** — 新しい順 / ステータス順(BA回答待ち → 担当者回答待ち → 完了)
- ✅ **相談の完了** — チャット画面の「完了にする」で完了に。完了した相談の案件はBAタブ・バッジから除外
- 🤖 **Claude API による自動回答** — 一般的な会計知識で答えられる質問はAIが即座に回答(`claude-opus-4-8`)
- ❓ **不足情報の聞き返し** — 情報不足のときはAIが短い質問+選択肢ボタンを表示
- 👤 **BAエスカレーション** — AIが回答できない質問はBAタブへ。「要対応」タップで自分を対応者に登録し、回答方針の選択(または自由入力・音声入力)→ 回答文(案)の生成 → 編集して送信
- 📖 **マニュアルの該当箇所の確認** — 各回答方針に関係する社内マニュアルの記載をAIが引用表示
- 📘 **社内ルール** — 回答時にAIが最優先で参照。相談やマニュアルから差分を抽出して追記、AIで整理してコンパクト化も可能
- 📚 **社内マニュアル** — PDF / テキスト / Markdown を追加(PDFは文字抽出+プレビュー)。回答時にAIが参照
- ✍️ **回答の癖(回答スタイル)** — アカウントごとに回答文の書き方を登録
- 🎤 **音声入力** — 回答方針を日本語音声で入力(Speech / マイク権限が必要)
- ⬇️ **Q&A履歴のエクスポート** — JSON / CSV(BOM付きUTF-8・Excel対応)を共有シートから書き出し
- 🔐 **メール+パスワードのログイン** — 新規登録時にニックネームと役割(担当者 / 財務=BA)を選択

## ビルド方法

1. [XcodeGen](https://github.com/yonaskolb/XcodeGen) でプロジェクトを生成(生成済みの `.xcodeproj` があればそのままでもOK):
   ```sh
   brew install xcodegen
   xcodegen generate
   ```
2. `ChatBotWest.xcodeproj` を Xcode で開く(初回は Firebase SDK を Swift Package Manager が自動解決)
3. Signing & Capabilities で自分の開発チームを選択
4. iPhone(シミュレータ or 実機)で Run

## Firebase 接続について

- Web版と同じ Firebase プロジェクト(`chatbotwest-5b568`)・同じワークスペース合言葉を埋め込みで使用しています(`ChatBotWest/App.swift`)
- `GoogleService-Info.plist` をターゲットに追加すると、そちらの設定が優先されます(Firebase コンソールで iOS アプリを登録する場合)
- Anthropic API キーはサーバー(Firebase Functions の `chat`)側で管理されるため、通常は端末に不要です。サーバー未設定時のみ、設定タブのAPIキー(フォールバック)が使われます

## 構成

```
project.yml            … XcodeGen プロジェクト定義(Firebase SPM 依存を含む)
ChatBotWest/
  App.swift            … エントリポイント + Firebase 初期化
  Models.swift         … Room / Message / Case / Manual / QaEntry(Firestore と同一構造)
  Prompts.swift        … トリアージ・回答案・社内ルール抽出などのプロンプト(Web版と同一)
  ClaudeService.swift  … Functions プロキシ経由の Claude 呼び出し(直接呼び出しフォールバック付き)
  CloudStore.swift     … Firestore 同期・アプリ状態・業務ロジック
  SampleData.swift     … デモ用サンプル相談・サンプルマニュアル
  Views/               … SwiftUI 画面(ログイン / 相談一覧 / チャット / BA / 社内ルール / マニュアル / 設定)
```

## Web版との対応

| Web版 | iOS版 |
|---|---|
| 質問者タブ(財務は「相談一覧」) | 質問者/相談一覧タブ |
| BAタブ | BAタブ(バッジ=未回答の案件数) |
| 社内ルールタブ + 🧹コンパクト | 社内ルールタブ + 🧹コンパクト |
| マニュアルタブ(PDF対応・プレビュー・ルール抽出) | マニュアルタブ(PDFKit でプレビュー・文字抽出) |
| 設定モーダル(サンプル・管理・回答の癖) | 設定タブ |
| ブラウザの戻る/スワイプ | NavigationStack の戻る |
| Web Speech API の音声入力 | SFSpeechRecognizer(ja-JP) |

データはすべて Firestore の `workspaces/{wid}/…`(rooms / cases / qa / manuals / members)を Web版と共有します。
