<p align="center">
  <img width="1456" height="484" alt="desktop-app-banner" src="Assets/README header.png"/>
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
  Pi-hole® インスタンスの監視と操作のための、ネイティブでモダンな macOS メニューバーアプリ——ブラウザのタブは不要です。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white&style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?logo=swift&logoColor=white&style=flat-square" alt="Swift 6.0" />
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="MIT License" />
  <img src="https://img.shields.io/github/v/release/pedrovieira/Holeberry?style=flat-square" alt="Latest release" />
  <img src="https://img.shields.io/badge/Pi--hole-v5%20%26%20v6-96C93C.svg?style=flat-square" alt="Pi-hole v5 & v6" />
</p>

## Holeberry とは？

Holeberry は、Pi-hole® をいつでも手元で操作できる軽量な macOS メニューバーアプリです。ブロッキングの状態やクエリ統計の確認、指定した時間だけ、または無期限でブロッキングを無効化、現在のブラウザタブのドメインをブロック解除、最近ブロックされたドメインの許可リストへの追加やブロック解除——すべて Pi-hole のウェブインターフェースを開かずに完結します。

Pi-hole® **v6** と **v5**（*完全にはテストされていません*）、複数インスタンス、グローバルキーボードショートカットに対応しています。

## インストール

1. [Releases](https://github.com/pedrovieira/Holeberry/releases) ページから最新の `Holeberry-<バージョン>.dmg` をダウンロードします。
2. DMG を開き、**Holeberry** を `Applications` フォルダにドラッグします。

**macOS Gatekeeper についての注意：** Holeberry は無料の Apple ID でビルドされており、有料の Apple Developer アカウントによる公証（notarization）を受けていません。そのため、macOS が「開発元不明のアプリ」として警告したり、初回起動時に隔離したりする場合があります。その警告が表示されたら、隔離フラグを削除して再度起動してください：

```bash
xattr -cr /Applications/Holeberry.app
```

## 動作環境

- **macOS 14（Sonoma）以降** —— Holeberry は Swift 6 で構築され、最新の macOS API を活用しています。
- Mac からアクセスできる Pi-hole® インスタンス（v6 または v5）。ローカルネットワーク上でも、その他の場所でも構いません。

## 機能

### 複数インスタンス

1 つのメニューで最大 **2 つの Pi-hole® インスタンス**を管理できます。Holeberry でのすべての操作——ブロッキング、ブロック解除、許可リストの変更など——は**すべてのインスタンスに同時に**適用されます。

これは重要なことです。Mac が最初の DNS サーバーだけを使うとは限らないからです。Holeberry を使えば、すべてのインスタンスが常に同期した状態を保ちます。サーバーごとのステータスドットと集計統計がメニューに直接表示されます。

<p align="center">
  <img width="700" height="351" alt="desktop-app-banner" src="Assets/max-connections.png"/>
</p>

### ステータスをひと目で

メニューバーのアイコンは Pi-hole® の健全性を常に反映し、複数サーバー構成ではインスタンスごとの状態も表示されます。メニューには全インスタンスの**総クエリ数とブロックされたドメイン数**も表示されます。

<p align="center">
  <img width="250" height="175" alt="desktop-app-banner" src="Assets/instaces-status.png"/>
</p>

### タイマー付きでブロッキングを無効化

ブロッキングを**グローバルに**、すべての Pi-hole® インスタンスで指定した時間だけ、または無期限で無効化できる便利な方法です。メニューバーの**タイマーピル**にカウントダウンが表示され、時間になるとブロッキングは自動的に再有効化されます。

<p align="center">
  <img width="422" height="164" alt="desktop-app-banner" src="Assets/menu-unblock.png"/>
</p>

### 今見ているブラウザタブをブロック解除

Holeberry は **WebKit（Safari、Orion）、Chrome/Chromium、Gecko（Firefox、Zen など）**の現在のタブを検出し、そのドメインをワンクリックでブロック解除します——Pi-hole のブロッキングでページが読み込めないときにぴったりです。[対応ブラウザの完全なリスト](docs/SUPPORTED-BROWSERS.md)を参照してください。

単一ドメインのブロック解除はグローバルな無効化より優れています：ページは読み込まれ、ネットワークの他の部分は保護されたままです。（スマート TV は同意しないでしょう——外の世界に大量のトラフィックを送るので、グローバルなブロック解除を喜ぶに違いありません。話を聞いてはいけません。）ドメインを許可リストに追加することもできます。

<p align="center">
  <img width="668" height="251" alt="desktop-app-banner" src="Assets/browser-unblock.png"/>
</p>

### 最近ブロックされたドメイン

Pi-hole® が最近ブロックしたドメイン（この Mac または全クライアント）を閲覧し、メニューから直接ブロック解除や許可リストへの追加ができます。

## 今後の予定

Holeberry は現在 Pi-hole® 専用のアプリですが、メニューバーのワークフローはそれだけにとどまる必要はありません。コミュニティからの要望が十分にあれば、将来のバージョンでは以下が追加される可能性があります：

- **他の DNS プロバイダーのサポート** —— AdGuard Home や Technitium が候補です。Pi-hole® を使っていない人向けに、同じ体験を提供します。
- **混在構成** —— Pi-hole® と AdGuard Home（または任意の組み合わせ）を並行して接続し、インスタンスごとのステータス、集計統計、プロバイダーをまたいだ同じワンクリック操作を提供します。

これは約束ではありません——優先順位はコミュニティの声で決まる要望リストです。実現してほしい機能があれば、[issue](https://github.com/pedrovieira/Holeberry/issues) を開いてください。

## FAQ

### Pi-hole の認証情報はどこに保存されますか？
macOS **キーチェーン** に保存されます——メールや Safari、システムが使うのと同じ安全なストレージです。Holeberry がパスワードをディスクに書き込むことはありません。

### パスワードなしの Pi-hole は使えますか？
使えます。パスワード未設定のインスタンス（v5・v6 とも）を完全にサポートしています——接続画面で「この Pi-hole にはパスワードがない」にチェックを入れてください。そのようなインスタンスには認証情報は一切保存されません。

### Holeberry にはどの権限が必要ですか？ なぜですか？
- **ローカルネットワーク**：Pi-hole インスタンスへの接続に必要です。
- **Automation（ブラウザアクセス）**：任意。ブラウザタブのブロック解除を有効にした場合のみ使用します。設定 → 一般でいつでも無効化できます。

### Holeberry は Pi-hole のウェブインターフェースを置き換えますか？
いいえ——置き換えるものではありません。Holeberry は日常の操作（ステータス確認、オン/オフ切り替え、ピンポイントのブロック解除）のリモコンです。詳細な設定（adlist、DHCP、gravity の更新など）には引き続きウェブインターフェースを使います。

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

## コントリビュート

バグ報告や機能リクエストは [issues](https://github.com/pedrovieira/Holeberry/issues) へお寄せください。PR は `main` ブランチをターゲットにし、既存のテストスイートが通るようにしてください。AI を利用したコントリビューションも歓迎します——AI 支援で作成した PR には、その旨と使用したツールを PR の説明に明記してください。大きな変更を計画している場合は、まず issue を開いてください——お互いの時間の節約になります。

## AI 支援による開発

このプロジェクトは主に AI によって書かれました。そのことを率直に伝えておきたいと思います——ただし、すべての段階で人間による強い指導を受けています：私です。コードの大半は AI が生成・洗練しましたが、アーキテクチャ、機能、スコープ、設計上の決定は、すべて私が指示しレビューしたものです。AI は加速装置であって、作者ではありません。このコードベースを今の形にしている選択は、すべて人間の選択です。AI はそこに到達するのを速くしただけです。

## 謝辞

- [Sparkle](https://github.com/sparkle-project/Sparkle) —— アップデートフレームワーク
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) —— グローバルショートカットの記録
- [Defaults](https://github.com/sindresorhus/Defaults) —— 型付きユーザーデフォルト
- [SymbolPicker](https://github.com/SzpakKamil/SymbolPicker) —— インスタンスアイコンの選択
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) —— プロジェクト生成
- [SwiftLint](https://github.com/realm/SwiftLint) と `swift-format` —— コードの品質を保つために

---

*Pi-hole® は Pi-hole LLC の登録商標です。Holeberry は独立したプロジェクトであり、Pi-hole LLC とは提携していません。*
