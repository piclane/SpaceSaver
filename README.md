<img src="space_layout.svg" width="56" height="56" align="left" style="margin-right:16px">

# SpaceSaver

**SpaceSaver** — モニタ構成ごとに macOS の仮想デスクトップ（Spaces）レイアウトを自動保存・復元する Hammerspoon モジュール。

<br clear="left">

ノートPCを自宅のモニタに繋いだり、Dock に接続したりするたびに、仮想デスクトップを手動で並べ直していませんか？
SpaceSaver は「どのモニタが繋がっているか」を検出し、そのモニタ構成に対応した Spaces の数・各 Space に置くウィンドウ・ウィンドウの位置とサイズを自動で復元します。

macOS の Spaces はモニタを切り替えるたびにリセットされてしまう問題があります。たとえば「自宅では 3 枚のモニタで合計 12 個の Space を使い、左モニタの Space 3 にターミナルを、中央モニタの Space 1 にブラウザを、Space 2 に IDE を置く」という運用をしていると、ノートPCだけで外出して戻ってきたあとは毎回すべて手動でやり直すことになります。

SpaceSaver はこの問題を次のように解決します：

1. **キャプチャ**（手動・任意のタイミング）  
   メニューバーアイコンまたはシェルコマンドで実行します。全 Space をひとつずつ自動で切り替えながら巡回し、各 Space に存在するウィンドウのアプリ情報・タイトル・位置・サイズを正確に記録します。記録結果は `~/.hammerspoon/space_layouts_<n>.yaml` に保存されます。**モニタ構成が異なるファイルには書き込まれないため**、自宅用・オフィス用・ノートPC単体用など複数の構成を独立して管理できます。

2. **復元**（自動・モニタ接続変化時）  
   Dock の着脱やモニタの接続・切断を検出すると、接続中のモニタ UUID の集合をキーに対応する YAML ファイルを自動で選択します。Space の数が不足していれば補完し、各 Space へウィンドウを移動してウィンドウの位置・サイズも元通りに設定します。フルスクリーン（緑ボタン）で占有している Space にも対応します。

3. **設定ファイルの手動調整**  
   生成された YAML は人間が読み書きしやすい形式で保存されます。ブラウザやターミナルのように実行中にウィンドウタイトルが変わるアプリには `titlePattern`（Lua パターン）を手書きで追記すれば、次の復元から自動でマッチします。`metadata` フィールドにはモニタ名や自由なメモを記録できます（復元には使用しません）。

# Features

- **構成ごとに独立した YAML ファイル**  
  `space_layouts_1.yaml`、`space_layouts_2.yaml`… と 1 構成 = 1 ファイル。  
  別構成でキャプチャしても既存ファイルを上書きしません。ファイル名は自由にリネーム可。

- **モニタ構成の自動検出と復元**  
  Dock 脱着などでモニタ構成が変わると `hs.screen.watcher` が検出し、  
  対応する YAML から Space 数・ウィンドウ配置・フレームを自動復元します。

- **ウィンドウの位置・サイズまで復元**  
  単に Space へ移動するだけでなく、`setFrame` でウィンドウのサイズと位置も元通りに。

- **フルスクリーン Space 対応**  
  緑ボタンで全画面化した Space（`type: fullscreen`）もキャプチャ・復元します。

- **可変タイトルのウィンドウに Lua パターン照合**  
  YAML に `titlePattern` を手書きすることで、タイトルが変わるアプリ（ブラウザ等）にも対応。

- **Kubernetes スタイルの YAML + JSON Schema**  
  `apiVersion: v1 / kind: SpaceLayouts` 形式。付属の `space_layouts.schema.json` により  
  VS Code 等のエディタで補完・バリデーションが効きます。

- **メニューバー & URL イベントから操作**  
  メニューバーアイコンのほか、シェルから `open -g "hammerspoon://space-capture"` でキャプチャを起動できます。

- **yq 非依存フォールバック**  
  yq が見つからない場合は JSON 形式（`space_layouts_<n>.json`）で動作を継続します。

# Requirement

* [Hammerspoon](https://www.hammerspoon.org/) 1.x
* [yq](https://github.com/mikefarah/yq) v4（YAML 入出力に使用。なければ JSON フォールバック）
* macOS のシステム設定：**デスクトップとDock > 「ディスプレイごとに異なるSpaceを表示」を有効**
* Hammerspoon に **アクセシビリティ権限** を付与

# Installation

### 1. yq をインストール

```bash
brew install yq
```

### 2. ファイルを `~/.hammerspoon/` に配置

```bash
# 必須
cp space_layout.lua    ~/.hammerspoon/
cp space_layout.svg    ~/.hammerspoon/

# YAML エディタで補完・バリデーションを使いたい場合
cp space_layouts.schema.json ~/.hammerspoon/

# シェルからキャプチャを起動したい場合（任意）
cp capture-layout.sh   ~/.hammerspoon/
chmod +x ~/.hammerspoon/capture-layout.sh
```

### 3. `~/.hammerspoon/init.lua` に追記

```lua
local spaceLayout = require("space_layout")
spaceLayout.start()
```

### 4. Hammerspoon をリロード

メニューバーの Hammerspoon アイコン > **Reload Config**

メニューバーに SpaceSaver のアイコンが表示されれば起動成功です。

# Usage

### キャプチャ（レイアウトを記録する）

現在のモニタ構成・各 Space のウィンドウ配置を記録します。  
**キャプチャ中は操作しないでください**（全 Space を自動で切り替えて巡回します）。

```bash
# メニューバーのアイコンから
⊞ > レイアウトをキャプチャ

# シェルから
open -g "hammerspoon://space-capture"
# または
~/.hammerspoon/capture-layout.sh
```

初回キャプチャで `~/.hammerspoon/space_layouts_1.yaml` が生成されます。

### 設定ファイルの手動編集

生成された YAML を手動で編集することで、可変タイトルへの対応や細かい調整ができます：

```yaml
# titlePattern で Lua パターンを指定（titleより優先）
- bundleID: "com.google.Chrome"
  title: "GitHub - google/..."     # キャプチャ時のタイトル（参照用）
  titlePattern: "^GitHub"          # "GitHub" で始まるタイトルにマッチ
  frame: { x: 0, y: 25, w: 1920, h: 1055 }
```

ファイル名は自由にリネームできます（例: `space_layouts_home_5screens.yaml`）。  
照合はファイル名ではなく、内部の screen UUID 集合で行われます。

### 復元（自動）

Dock 脱着などでモニタ構成が変わると、対応する YAML から自動復元されます。  
手動で再実行する場合：

```bash
# メニューバーから
⊞ > 再リストア

# シェルから
open -g "hammerspoon://space-restore"
```

### デバッグ

```lua
-- Hammerspoon コンソールで実行
spaceLayout.dump()
```

# Configuration Reference

キャプチャで生成される `space_layouts_<n>.yaml` のスキーマ詳細です。  
`space_layouts.schema.json` が同じディレクトリにあれば VS Code（YAML 拡張）で補完・バリデーションが効きます。

### ファイル全体の構造

```yaml
# yaml-language-server: $schema=./space_layouts.schema.json
apiVersion: v1          # 固定値
kind: SpaceLayouts      # 固定値
screens:                # モニタ UUID → screen オブジェクト のマップ
  "<UUID>":
    metadata: ...
    spaces: [...]
```

| フィールド | 型 | 説明 |
|---|---|---|
| `apiVersion` | `"v1"` | 固定。将来のバージョン互換のために保持。 |
| `kind` | `"SpaceLayouts"` | 固定。 |
| `screens` | object | キーがモニタの UUID（`hs.screen:getUUID()`）。この UUID の集合がモニタ構成の識別子になる。 |

> **ファイルの選択ロジック**：`~/.hammerspoon/space_layouts_*.yaml` を順に読み込み、`screens` のキー集合が現在接続中のモニタ UUID 集合と一致するファイルが選ばれます。ファイル名は単なるラベルであり、照合には使用しません。

---

### `screens.<UUID>`（screen オブジェクト）

```yaml
screens:
  "5FEEC91C-8A4F-44AE-A28A-E335DD6F0ADD":
    metadata:
      name: "LG UltraWide"
      frame: { x: -3440, y: 0, w: 3440, h: 1440 }
      note: "左モニタ"       # 自由なキーを追加可
    spaces:
      - ...
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `metadata` | object | — | ユーザー編集用メタデータ。**復元には使用しない**。 |
| `metadata.name` | string | — | モニタ名（`hs.screen:name()`）。キャプチャ時に自動入力・更新。 |
| `metadata.frame` | frame | — | モニタの配置と解像度（`hs.screen:frame()`）。キャプチャ時に自動入力・更新。**復元には使用しない**。 |
| `metadata.*` | any | — | その他のキーは自由に追加・保持される。再キャプチャしても消えない。 |
| `spaces` | array | **必須** | この画面の Space リスト。**配列の順番が Space の並び順**（左＝インデックス小）。 |

---

### `spaces[]`（space オブジェクト）

```yaml
spaces:
  - type: user          # 通常の仮想デスクトップ
    windows: [...]
  - type: fullscreen    # 緑ボタンで全画面占有している Space
    windows: [...]
```

| フィールド | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `type` | `"user"` \| `"fullscreen"` | — | `"user"` | `"fullscreen"` は緑ボタン（フルスクリーン）で画面を占有している Space。 |
| `windows` | array | **必須** | — | この Space に配置するウィンドウのリスト。 |

---

### `windows[]`（window オブジェクト）

```yaml
windows:
  - bundleID: "com.googlecode.iterm2"
    title: "bash — 80×24"
    titlePattern: "^bash"       # titlePattern がある場合はこちらを優先
    frame: { x: 0, y: 25, w: 1200, h: 800 }
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `bundleID` | string | **必須** | アプリの Bundle ID（例: `com.googlecode.iterm2`）。まずこれでウィンドウ候補を絞り込む。 |
| `title` | string | — | キャプチャ時のウィンドウタイトル（完全一致）。`titlePattern` がある場合は参照用のみ。 |
| `titlePattern` | string | — | Lua パターンによるウィンドウタイトル照合。`title` より優先される。タイトルが変わるアプリ（ブラウザ・ターミナル等）で有用。 |
| `frame` | frame | — | ウィンドウの位置とサイズ。省略すると復元時にリサイズしない。 |

**ウィンドウ照合のルール**：

1. `bundleID` が一致するウィンドウをプールとして絞り込む
2. `titlePattern` が指定されていれば `string.find(title, titlePattern)` で照合
3. `titlePattern` がなければ `title` と完全一致で照合
4. タイトル一致なしの場合、同じ `bundleID` の未割り当てウィンドウをフォールバックとして使用

**Lua パターンの書き方**（PCRE とは一部異なる）：

| 記法 | 意味 | 例 |
|---|---|---|
| `^` | 先頭 | `"^GitHub"` → "GitHub" で始まる |
| `$` | 末尾 | `"%.py$"` → ".py" で終わる |
| `%.` | リテラルの `.`（`.` は任意1文字） | `"v%d+%.%d+"` → "v1.23" 等 |
| `%d` | 数字 | `"%d+` px"` → "123 px" |
| `%a` | アルファベット | |
| `.*` | 任意の文字列 | `"^foo.*bar$"` |
| `[...]` | 文字クラス | `"[Ee]rror"` |

> **注意**：Lua パターンには `|`（OR 交替）がありません。OR 条件は `titlePattern` を複数のウィンドウエントリとして記述してください。

---

### `frame`（共通オブジェクト）

```yaml
frame: { x: 0, y: 25, w: 1920, h: 1055 }
```

| フィールド | 型 | 説明 |
|---|---|---|
| `x` | number | 左端の X 座標（スクリーン座標系。プライマリディスプレイ左上が原点）。 |
| `y` | number | 上端の Y 座標。メニューバーぶんのオフセット（通常 25）が含まれる。 |
| `w` | number | 幅（ポイント単位）。Retina ディスプレイでも論理ピクセル値。 |
| `h` | number | 高さ（ポイント単位）。 |

---

### 完全な例

```yaml
# yaml-language-server: $schema=./space_layouts.schema.json
apiVersion: v1
kind: SpaceLayouts
screens:
  # プライマリ（中央）モニタ
  "5FEEC91C-8A4F-44AE-A28A-E335DD6F0ADD":
    metadata:
      name: "DELL U2723D"
      frame: { x: 0, y: 0, w: 2560, h: 1440 }
    spaces:
      - type: user
        windows:
          - bundleID: "com.googlecode.iterm2"
            title: "bash — iTerm2"
            titlePattern: "— iTerm2$"
            frame: { x: 0, y: 25, w: 1280, h: 1415 }
          - bundleID: "com.jetbrains.intellij"
            title: "MyProject – main.java"
            titlePattern: "^MyProject"
            frame: { x: 1280, y: 25, w: 1280, h: 1415 }
      - type: user
        windows:
          - bundleID: "com.google.Chrome"
            title: "Google"
            titlePattern: "^Google"
            frame: { x: 0, y: 25, w: 2560, h: 1415 }
      - type: fullscreen
        windows:
          - bundleID: "com.spotify.client"
            title: "Spotify"

  # 左モニタ
  "A1B2C3D4-E5F6-7890-ABCD-EF1234567890":
    metadata:
      name: "LG UltraWide"
      frame: { x: -3440, y: 0, w: 3440, h: 1440 }
      note: "左側のウルトラワイド"
    spaces:
      - type: user
        windows:
          - bundleID: "com.tinyspeck.slackmacgap"
            title: "Slack"
            frame: { x: -3440, y: 25, w: 1720, h: 1415 }
          - bundleID: "com.apple.mail"
            title: "インボックス"
            titlePattern: "インボックス"
            frame: { x: -1720, y: 25, w: 1720, h: 1415 }
```

# Note

- キャプチャはアクティブになった Space のウィンドウのみ正確に取得できます。Mission Control が一瞬表示されますが、**システム設定 > アクセシビリティ > 「視差効果を減らす」** を有効にすると目立たなくなります。
- ウィンドウの照合は `bundleID + タイトル`（または `titlePattern`）のベストエフォートです。タイトルが完全に一意でないアプリでは意図しないウィンドウと照合されることがあります。
- 復元時に余剰な Space は削除しません（不足分の追加のみ）。不要な Space は手動で削除してください。
- フルスクリーン Space の並び順は復元できません（ベストエフォート）。
- 再キャプチャすると `screens.<UUID>.metadata.name` と `metadata.frame` は実モニタ情報で上書きされます。ユーザーが追加した他のメタデータキーは保持されます。

# Author

* piclane

# License

SpaceSaver is under [MIT license](https://en.wikipedia.org/wiki/MIT_License).
