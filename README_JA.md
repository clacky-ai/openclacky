# OpenClacky

[![Build](https://img.shields.io/github/actions/workflow/status/clacky-ai/openclacky/main.yml?label=build&style=flat-square)](https://github.com/clacky-ai/openclacky/actions)
[![Release](https://img.shields.io/gem/v/openclacky?label=release&style=flat-square&color=blue)](https://rubygems.org/gems/openclacky)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1.0-red?style=flat-square)](https://www.ruby-lang.org)
[![Downloads](https://img.shields.io/gem/dt/openclacky?label=downloads&style=flat-square&color=brightgreen)](https://rubygems.org/gems/openclacky)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)](LICENSE.txt)

<p align="center">
  <a href="README.md">English</a> · <a href="README_CN.md">简体中文</a> · <a href="README_JA.md">日本語</a>
</p>

> コントリビュートする場合は、PR を作成する前に **[CONTRIBUTING.md](./CONTRIBUTING.md)** をお読みください。

**最もトークン効率の高いオープンソース AI エージェント。**

OpenClacky は Claude Code と同等の性能を同等のコストで実現しつつ、他のオープンソースエージェントと比べて大幅にコストを削減します（OpenClaw 比で約 50%、Hermes 比で約 3 倍安価）。100% オープンソース（MIT）、任意の OpenAI 互換モデルで BYOK が可能で、2 年にわたるエージェント開発（Agentic R&D）とハーネスエンジニアリングの上に構築されています。

> Web サイト: https://www.openclacky.com/ · 出資元 **MiraclePlus · ZhenFund · Sequoia China · Hillhouse Capital**

## なぜ OpenClacky なのか？

同じタスクで、どれだけ支払いますか？ 同等のエージェントワークロードにおいて、OpenClacky は主流の代替手段と比べて大量のトークン消費を節約します。

| エージェント | 相対コスト | 備考 |
|---|---|---|
| **OpenClacky** | **約 0.8** | 16 ツール · キャッシュヒット率約 100% · サブエージェントルーティング |
| Claude Code | 1.0×（基準） | 世界クラスのハーネス、クローズドソースのサブスクリプション |
| OpenClaw | 約 1.5× | 同等のハーネスエージェント |
| Hermes | 約 3× | 52 個の組み込みツール — スキーマの肥大化が約 3〜4 倍 |

*数値は社内の一般的なエージェントタスクで計測した平均値であり、Claude Code を基準としています。詳細なベンチマークレポートは GitHub で公開予定です。*

## 機能比較

エージェントのコア性能はこの分野でおおむね横並びであり、本当の差別化要因は **コスト、オープン性、Skill の進化、そして統合機能** です。

| 機能 | Claude Code | OpenClaw | Hermes | **OpenClacky** |
|---|:---:|:---:|:---:|:---:|
| トークンコスト | 1.0× | 約 1.5× | 約 3× | **約 0.8** |
| オープンソース | ❌ クローズド | ✅ オープン | ✅ オープン | ✅ MIT |
| BYOK / モデルの自由度 | ❌ Anthropic のみ | ✅ | ✅ | ✅ |
| Skill の自己進化 | ❌ | ❌ | ✅ | ✅ |
| IM 統合（Feishu/WeCom/WeChat/Discord/Telegram） | ❌ | ✅ | ✅ | ✅ |

## どうやってコストを下げているのか

機能を削るのではなく、すべてのレイヤーで正しい選択を積み重ねることで実現しています。

### 1. 超高水準のキャッシュヒット率
セッションを再起動しない、ダブルキャッシュマーカー、**Insert-then-Compress（挿入してから圧縮）** — システムプロンプトは決して書き換えられないため、圧縮後もキャッシュを再利用できます。**計測されたキャッシュヒット率: ほぼ 100%。**

### 2. 最小限のツールセット
**コアツールはわずか 16 個** です。機能は単一の `invoke_skill` メタツールを介して Skill エコシステムにオフロードされます。指標はツールの数ではなく、タスクの完了率です。

| OpenClacky | Claude Code | OpenClaw | Hermes |
|:--:|:--:|:--:|:--:|
| **16** | 40+ | 23 | 52 |

### 3. アイドル時の自動圧縮
会議に行く、コーヒーを淹れる — その間にエージェントは長いコンテキストをバックグラウンドで圧縮し、キャッシュを事前にウォームアップします。戻ってきて最初に送るメッセージは直接キャッシュにヒットします。**コールドスタート時の初回トークンコストを 50% 以上削減。**

### 4. BYOK — モデルを自分で選び、コストを自分で決める
任意の OpenAI 互換 API をプラグアンドプレイで利用できます。公式の直接接続、集約ルーティング、互換リレー — 選択は 100% あなた次第です。コードには Claude を使い、サブタスクは自動的に DeepSeek にルーティングして、さらにトークンを節約しましょう。

**2 年 · 3 世代のエージェントアーキテクチャ · 6 つのコアハーネスエンジニアリングの意思決定** の上に構築されています。

## Skill — エージェントの魂

- **`/` で呼び出す** — 瞬時の閲覧、あいまい検索、ダイレクトコール。何百もの Skill を指先で操作できます。
- **自然言語で Skill を作成** — やりたいことを説明するだけで、エージェントが `SKILL.md` を起草し、手順を分解し、検証を実行します。コードは不要です。
- **自己進化** — 各実行のあと、エージェントは実行コンテキストと結果に基づいて Skill を更新します。次回の呼び出しはより安定し、より正確になります。
- **オープンで互換性が高い** — Claude Skills / Markdown Pack / カスタム形式をサポートします。
- **収益化が可能** — 洗練された Skill はパッケージ化して販売でき、暗号化配布、License 管理、作者が設定する価格設定に対応します。

## インストール

### デスクトップインストーラー（推奨）

ダブルクリックでインストール — 環境、依存関係、Skill のすべてが自動的にセットアップされます。

- **macOS** — [`.dmg` をダウンロード](https://oss.1024code.com/openclacky-installer/official/openclacky-installer.dmg)（Apple Silicon / Intel）
- **Windows** — [`.exe` をダウンロード](https://oss.1024code.com/openclacky-installer/official/openclacky-installer.exe)（Windows 10 2004+ / Windows 11）

その他のオプション: https://www.openclacky.com/

### コマンドライン

ワンラインインストール（Mac/Ubuntu）:

```bash
/bin/bash -c "$(curl -sSL https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install.sh)"
```

Windows:

```bash
powershell -c "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install.ps1')))"
```

または Ruby（3.x/4.x）を使う場合:

**要件:** Ruby >= 3.1.0

```bash
gem install openclacky
```

詳細はこちら: https://www.openclacky.com/docs/installation

### Docker

#### ビルド済みイメージ（GHCR）

バージョンタグ（`v*`）が付くと GitHub Container Registry にイメージが自動公開されます。

```bash
# <owner> をリポジトリオーナーに置き換えてください（例: clacky-ai またはあなたのフォーク）
docker pull ghcr.io/<owner>/openclacky:latest
# またはバージョンを固定する場合:
# docker pull ghcr.io/<owner>/openclacky:1.5.3
```

**Linux:**

```bash
docker run -d --name openclacky --network=host \
  -e CLACKY_ACCESS_KEY="" \
  -v openclacky-data:/root/.clacky \
  ghcr.io/<owner>/openclacky:latest
```

`--network=host` は、コンテナ内のエージェントがホスト上で動作する Chrome のリモートデバッグポートに到達するために必要です。

**macOS / Windows:**

```bash
docker run -d --name openclacky -p 7070:7070 \
  -e CLACKY_ACCESS_KEY="" \
  -v openclacky-data:/root/.clacky \
  ghcr.io/<owner>/openclacky:latest
```

> **注意:** macOS/Windows では `--network=host` がサポートされていないため、ブラウザの自動化が制限される場合があります。

起動後、**http://localhost:7070** を開いてください。

#### ソースからビルド

```bash
git clone https://github.com/clacky-ai/openclacky.git
cd openclacky
# オプション: OCI イメージバージョンラベルを設定
docker build --build-arg VERSION=1.5.3 -t openclacky .
docker run -d -p 7070:7070 -e CLACKY_ACCESS_KEY="" openclacky
```

環境変数:

| 変数 | 説明 |
|---|---|
| `CLACKY_ACCESS_KEY` | アクセスキーで Web UI を保護します（空の場合はパブリックモード；`0.0.0.0` にバインドする場合は必須） |


## クイックスタート

### ターミナル（CLI）

```bash
openclacky            # カレントディレクトリで対話型エージェントを起動
```

### Web UI

```bash
openclacky server     # デフォルト: http://localhost:7070
```

**http://localhost:7070** を開くと、マルチセッション対応の本格的なチャットインターフェースが利用できます — コーディング、コピーライティング、リサーチのセッションを並行して実行できます。

オプション:

```bash
openclacky server --port 8080        # カスタムポート
openclacky server --host 0.0.0.0     # すべてのインターフェースでリッスン（リモートアクセス）
```

## 設定

```bash
$ openclacky
> /config
```

**API Key**、**Model**、**Base URL**（任意の OpenAI 互換プロバイダー）を設定します。

標準でサポート: **Claude (Anthropic) · GPT (OpenAI) · DeepSeek · Kimi (Moonshot) · MiniMax · OpenRouter** — または任意のカスタムエンドポイント。

## コーディングのユースケース

OpenClacky は汎用 AI コーディングアシスタントとして機能します — フルスタックアプリの雛形作成、機能追加、あるいは未知のコードベースの探索が可能です:

```bash
$ openclacky
> /new my-app        # 新しいプロジェクトの雛形を作成
> メールとパスワードによるユーザー認証を追加して
> 決済モジュールはどのように動作しますか？
```

## Star History

<a href="https://www.star-history.com/?repos=clacky-ai%2Fopenclacky&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=clacky-ai/openclacky&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=clacky-ai/openclacky&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=clacky-ai/openclacky&type=date&legend=top-left" />
 </picture>
</a>

## 上級者向け — クリエイタープログラム

すでにパワーユーザーたちは、自身のワークフローを OpenClacky 上の垂直特化型 AI エキスパートへと変えています — 暗号化配布、License 管理、自分で設定する価格。法務、医療、ファイナンシャルプランニングなど、さまざまな分野で展開されています。

詳細はこちら: https://www.openclacky.com/ → Creators

## ソースからのインストール

```bash
git clone https://github.com/clacky-ai/openclacky.git
cd openclacky
bundle install
bin/clacky
```

## 信頼性と信用

- **100% オープンソース** — MIT ライセンス、すべてのコードが公開され、すべての意思決定が追跡可能
- **2 年にわたるエージェント開発（Agentic R&D）** — 3 世代のアーキテクチャ
- **16 個のコアツール** — 設計思想としての最小主義
- **出資元** MiraclePlus · ZhenFund · Sequoia China · Hillhouse Capital

## コントリビューター

すべてのコード、バグ報告、そして丁寧なレビューが大切です。OpenClacky をより良くしてくださり、ありがとうございます。

<a href="https://github.com/clacky-ai/openclacky/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=clacky-ai/openclacky" />
</a>

## コントリビュート

バグ報告とプルリクエストは GitHub（ https://github.com/clacky-ai/openclacky ）で歓迎しています。コントリビューターは[行動規範](https://github.com/clacky-ai/openclacky/blob/main/CODE_OF_CONDUCT.md)を遵守することが求められます。

## ライセンス

[MIT ライセンス](https://opensource.org/licenses/MIT)のもとでオープンソースとして利用可能です。
