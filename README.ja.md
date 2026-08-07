<p align="center">
  <img src="Sources/Holeberry/Resources/AppIcon.icon/Assets/logo_transparent.png" alt="Holeberry" width="128" />
</p>

<h1 align="center">Holeberry</h1>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="https://holeberryapp.com">Website</a>
</p>

<p align="center">
  <b>Pi-hole が、メニューバーに。</b><br />
  Pi-hole インスタンスの監視と操作のための、ネイティブでモダンな macOS メニューバーアプリ——ブラウザのタブは不要です。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white&style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?logo=swift&logoColor=white&style=flat-square" alt="Swift 6.0" />
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="MIT License" />
  <img src="https://img.shields.io/github/v/release/pedrovieira/Holeberry?style=flat-square" alt="Latest release" />
  <img src="https://img.shields.io/badge/Pi--hole-v5%20%26%20v6-96C93C.svg?style=flat-square" alt="Pi-hole v5 & v6" />
</p>

<!-- TODO: メニューバーのアイコンと開いたポップアップの実写スクリーンショットに差し替えてください。README で最も重要なビジュアルです——ステータスドット、統計行、「ブロッキングを無効化」サブメニューが表示されたステータスメニューを掲載してください。 -->

## Holeberry とは？

Holeberry は、Pi-hole をいつでも手元で操作できる軽量な macOS メニューバーアプリです。ブロッキングの状態やクエリ統計の確認、数秒間または任意の時間だけブロッキングを無効化、現在のブラウザタブのドメインをブロック解除、最近ブロックされたドメインの許可リストへの追加やブロック解除——すべて Pi-hole のウェブインターフェースを開かずに完結します。

Pi-hole **v5 / v6**、複数インスタンス、グローバルキーボードショートカットに対応しています。

## インストール

### GitHub Releases（推奨）

1. [Releases](https://github.com/pedrovieira/Holeberry/releases) ページから最新の `Holeberry-<バージョン>.dmg` をダウンロードします。
2. DMG を開き、**Holeberry** を「アプリケーション」フォルダにドラッグします。
3. Holeberry を起動します——メニューバーに常駐します。

**macOS Gatekeeper についての注意：** Holeberry は無料の Apple ID でビルドされており、有料の Apple Developer アカウントによる公証（notarization）を受けていません。そのため、macOS が「開発元不明のアプリ」として警告したり、初回起動時に隔離したりする場合があります。その警告が表示されたら、隔離フラグを削除して再度起動してください：

```bash
xattr -dr com.apple.quarantine /Applications/Holeberry.app
```

Holeberry は [Sparkle](https://sparkle-project.org/) による自動アップデートに対応しています。

### Homebrew

Homebrew cask は準備中です。それまでは上記のリリース DMG をご利用ください。

## 動作環境

- **macOS 14（Sonoma）以降** —— Holeberry は Swift 6 で構築され、最新の macOS API を活用しています。
- Mac からアクセスできる Pi-hole インスタンス（v5 または v6）。ローカルネットワーク上でも、その他の場所でも構いません。

## 機能

### ステータスをひと目で

メニューバーのアイコンは Pi-hole の健全性を常に反映します。複数サーバー構成ではインスタンスごとの状態も表示されます：

- 🟢 **ブロッキング有効** —— すべて正常にブロッキング中
- ⚪ **ブロッキング無効** —— オフ（またはタイマー設定中）
- 🟠 **部分的にブロッキング有効** —— インスタンス間で状態が一致していません
- 🔴 **インスタンスに接続できません** —— 1 つ以上のインスタンスに到達できません

メニューには全インスタンスの**総クエリ数とブロックされたドメイン数**も表示されます。

### タイマー付きでブロッキングを無効化

ブロッキングを **10 秒、30 秒、5 分、任意の時間**、または**無期限**でオフに——タイマーが切れると自動的に再有効化されます。広告ブロックをオンに戻し忘れる心配はもうありません。

### 今見ているタブをブロック解除

Holeberry は **Safari、Chrome/Chromium、Firefox、Zen Browser** の現在のタブを検出し、そのドメインを 10 秒、30 秒、5 分、または任意の時間だけブロック解除したり、許可リストに追加したりできます。読み込めないリンクや動画にぴったりです。

### 最近ブロックされたドメイン

Pi-hole が最近ブロックしたドメイン（この Mac または全クライアント）を閲覧し、メニューから直接ブロック解除や許可リストへの追加ができます。

### 複数インスタンス

複数の Pi-hole インスタンスを 1 つのメニューで管理：サーバーごとのステータスドット、クエリ/ブロック統計の集計、インスタンスの停止や状態不一致を明確に警告します。

### Pi-hole v5 & v6

Pi-hole のバージョンを自動検出し、それぞれに合った方法で通信します——v5 の Web API、またはセッション認証付きの v6 REST API。認証情報は macOS **キーチェーン** に安全に保存され、平文で保存されることはありません。

### グローバルキーボードショートカット

ブロッキング無効化（10 秒 / 30 秒 / 5 分 / 任意 / 無期限）、再有効化、現在のタブのブロック解除にグローバルショートカットを割り当てられます——Holeberry がバックグラウンドでも動作します。

### 自動検出

ローカルネットワークのスキャンと、Mac が現在使用している DNS サーバーの確認によって Pi-hole インスタンスを自動的に見つけます（Tailscale や VPN 経由のリモートインスタンスも検出できます）。セットアップは多くの場合「クリックして接続」だけです。

## Holeberry を作った理由

Pi-hole のウェブインターフェースは素晴らしい——すでにブラウザを開いているなら。しかし、ちょっとした操作のたびに `pi.hole/admin` へ行く必要がありました：ブロッキングを切り替え、ページの読み込みを待ち、もう一度クリックし、そして再有効化を忘れないようにする。また、試した macOS クライアントには、私が実際に使うワークフロー——今見ているタブのドメインを正確にブロック解除する機能、ドメイン単位のタイマー、複数インスタンスにわたる正確なステータス——がありませんでした。

そこで Holeberry を作りました：Pi-hole の操作を macOS の第一級市民として扱う、ネイティブでメニューバーのみのアプリ——高速で、キーボード駆動で、ネットワークの状態に正直なアプリです。

名前の由来？ Pi-hole は Raspberry Pi で動くから——*berry* がしっくりきました。

これはエンジニアリングへの愛情のこもった作品でもあります：Swift 6 の厳格な並行処理、ローカル Swift パッケージ（`HoleberryCore`）に抽出されたプロトコル駆動のコア、そして手厚くテストされたサービス層——オープンソースの貢献者として読んでみたいと思えるコードベースです。

## 今後の予定

Holeberry は現在 Pi-hole 専用のアプリですが、メニューバーのワークフローはそれだけにとどまる必要はありません。コミュニティからの要望が十分にあれば、将来のバージョンでは以下が追加される可能性があります：

- **他の DNS プロバイダーのサポート** —— AdGuard Home や Technitium が候補です。Pi-hole を使っていない人向けに、同じ体験を提供します。
- **混在構成** —— Pi-hole と AdGuard Home（または任意の組み合わせ）を並行して接続し、インスタンスごとのステータス、集計統計、プロバイダーをまたいだ同じワンクリック操作を提供します。

これは約束ではありません——優先順位はコミュニティの声で決まる要望リストです。実現してほしい機能があれば、[issue](https://github.com/pedrovieira/Holeberry/issues) を開いて知らせてください。支持が多ければ多いほど、優先度は上がります。

## はじめに

1. **Pi-hole を追加** —— 自動検出、または手動で（URL、API トークン / パスワード、任意のラベルとアイコン）。
2. **求められたら権限を許可**：
   - **ローカルネットワーク** —— Pi-hole インスタンスに接続するために必要です。
   - **Automation（自動化）** —— ブラウザタブのブロック解除を有効にした場合のみ使用します。Holeberry がブラウザの現在のタブ URL を読み取ってブロック解除します。
3. **ショートカットを設定** —— 「設定 → ショートカット」で、またはデフォルトのままでも。

以上です。あとはすべてメニューバーで完結します。

## スクリーンショット

<!-- TODO: スクリーンショットをここに追加——メニューバーのポップアップ（ステータス + 操作）、ブラウザタブのブロック解除セクション、設定ウィンドウ（サーバー / ショートカットタブ）。 -->

## FAQ

### Holeberry は Pi-hole v5 と v6 に対応していますか？
はい。バージョンを自動検出し、各インスタンスに正しい API を設定します。v6 セッションの認証情報は自動的に更新され、macOS キーチェーンに保存されます。

### Pi-hole の認証情報はどこに保存されますか？
macOS **キーチェーン** に保存されます——メールや Safari、システムが使うのと同じ安全なストレージです。Holeberry がパスワードをディスクに書き込むことはありません。

### Holeberry にはどの権限が必要ですか？ なぜですか？
- **ローカルネットワーク**：Pi-hole インスタンスへの接続に必要です。
- **Automation（ブラウザアクセス）**：任意。ブラウザタブのブロック解除を有効にした場合のみ使用します。設定 → 一般でいつでも無効化できます。

### Holeberry は Pi-hole のウェブインターフェースを置き換えますか？
いいえ——置き換えるものではありません。Holeberry は日常の操作（ステータス確認、オン/オフ切り替え、ピンポイントのブロック解除）のリモコンです。詳細な設定（adlist、DHCP、gravity の更新など）には引き続きウェブインターフェースを使います。

### Holeberry は無料ですか？
はい——[MIT ライセンス](LICENSE) のオープンソースで、自由に利用・フォーク・学習できます。

### ブラウザタブが表示されないのはなぜですか？
「設定 → 一般」でブラウザタブのブロック解除を有効にし、Holeberry にブラウザの Automation 権限が必要です（初回使用時にシステム設定で許可）。

## ソースからビルド

```bash
git clone https://github.com/pedrovieira/Holeberry.git
cd Holeberry
open Holeberry.xcodeproj
```

**Holeberry** scheme を選択し、実行（⌘R）します。

コントリビューター向けの注意：

- このプロジェクトは [XcodeGen](https://github.com/yonaskolb/XcodeGen) を使用しています——`project.yml` を変更したら `xcodegen generate` で再生成してください。
- アプリターゲットには [SwiftLint](https://github.com/realm/SwiftLint) と `swift-format` を strict モードで実行するプリビルドスクリプトがあります。インストールしていないとビルドが警告を出します。
- コアロジックは `HoleberryCore` Swift パッケージにあり、独自のテストスイートがあります——`cd Packages/HoleberryCore && swift test`。

## プロジェクト構成

```
Holeberry/
├── project.yml                  # XcodeGen 設定 — `xcodegen generate` で再生成
├── Sources/Holeberry/           # アプリターゲット（メニューバー UI のみ）
│   ├── App/                     # アプリのライフサイクルとアップデーター
│   ├── MenuBar/                 # メニューバーのコントローラー・ビルダー
│   ├── Components/              # 再利用可能な UI ビュー
│   ├── Shortcuts/               # グローバルキーボードショートカット
│   ├── Settings/                # 設定ウィンドウの UI
│   ├── Support/                 # Info.plist、entitlements
│   └── Resources/               # アセット、アプリアイコン
└── Packages/HoleberryCore/      # ビジネスロジックとテストスイート
    ├── Sources/HoleberryCore/
    │   ├── Models/              # 値型
    │   ├── Networking/          # HTTP 層、到達可能性、リトライ
    │   ├── Persistence/         # キーチェーンとデフォルトキー
    │   ├── Services/            # Auth、BrowserDetector、Pihole サービス
    │   └── Utils/               # 汎用ユーティリティ
    └── Tests/HoleberryCoreTests/
```

## コントリビュート

バグ報告や機能リクエストは [issues](https://github.com/pedrovieira/Holeberry/issues) へお寄せください。PR は `main` ブランチをターゲットにし、既存のテストスイートが通るようにしてください。AI を利用したコントリビューションも歓迎します——AI 支援で作成した PR には、その旨と使用したツールを PR の説明に明記してください。大きな変更を計画している場合は、まず issue を開いてください——お互いの時間の節約になります。

## AI 支援による開発

このプロジェクトは主に AI によって書かれました。そのことを率直に伝えておきたいと思います——ただし、すべての段階で人間による強い指導を受けています：私です。コードの大半は AI が生成・洗練しましたが、アーキテクチャ、機能、スコープ、設計上の決定は、すべて私が指示しレビューしたものです。AI は加速装置であって、作者ではありません。このコードベースを今の形にしている選択——プロトコル駆動の設計、`HoleberryCore` に抽出されたテスト可能なコア、Swift 6 の厳格な並行処理——は人間の選択です。AI はそこに到達するのを速くしただけです。

## 謝辞

- [Sparkle](https://github.com/sparkle-project/Sparkle) —— アップデートフレームワーク
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) —— グローバルショートカットの記録
- [Defaults](https://github.com/sindresorhus/Defaults) —— 型付きユーザーデフォルト
- [SymbolPicker](https://github.com/SzpakKamil/SymbolPicker) —— インスタンスアイコンの選択
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) —— プロジェクト生成
- [SwiftLint](https://github.com/realm/SwiftLint) と `swift-format` —— コードの品質を保つために

## ライセンス

[MIT](LICENSE) © 2026 Pedro Vieira

---

*Pi-hole® は Pi-hole LLC の登録商標です。Holeberry は独立したプロジェクトであり、Pi-hole LLC とは提携していません。*
