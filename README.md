<img src="space_layout.svg" width="56" height="56" align="left" style="margin-right:16px">

# SpaceSaver

**SpaceSaver** — モニタ構成ごとに macOS の仮想デスクトップ（Spaces）レイアウトを自動保存・復元する Hammerspoon モジュール。

<br clear="left">

ノートPCを自宅のモニタに繋いだり、Dock に接続したりするたびに、仮想デスクトップを手動で並べ直していませんか？
SpaceSaver は「どのモニタが繋がっているか」を検出し、そのモニタ構成に対応した Spaces の数・各 Space に置くウィンドウ・ウィンドウの位置とサイズを自動で復元します。

macOS の Spaces はモニタを切り替えるたびにリセットされてしまう問題があります。たとえば「自宅では 3 枚のモニタで合計 12 個の Space を使い、左モニタの Space 3 にターミナルを、中央モニタの Space 1 にブラウザを、Space 2 に IDE を置く」という運用をしていると、ノートPCだけで外出して戻ってきたあとは毎回すべて手動でやり直すことになります。

SpaceSaver はこの問題を次のように解決します：

1. **キャプチャ**（手動・任意のタイミング）  
   メニューバーアイコンまたはシェルコマンドで実行します。全 Space をひとつずつ自動で切り替えながら巡回し、各 Space に存在するウィンドウのアプリ情報・タイトル・位置・サイズを正確に記録します。記録結果はデータディレクトリ（デフォルト `~/.hammerspoon/`）の `space_layouts_<n>.yaml` に保存されます。**モニタ構成が異なるファイルには書き込まれないため**、自宅用・オフィス用・ノートPC単体用など複数の構成を独立して管理できます。再キャプチャしても既存のエントリは引き継がれるので、手書きした `titlePattern` は失われません。

2. **復元**（自動・モニタ接続変化時）  
   Dock の着脱やモニタの接続・切断を検出すると、接続中のモニタ UUID の集合をキーに対応する YAML ファイルを自動で選択します。Space の数が足りなければ追加し、多すぎれば末尾から削除して YAML どおりの数に揃えたうえで、各 Space へウィンドウを移動し位置・サイズも元通りに設定します。フルスクリーン（緑ボタン）で占有している Space にも対応します。キャプチャと違い**復元は Space を巡回しません**。既にあるべき Space にいるウィンドウは位置・サイズを直すだけなので、多くの場合は画面が切り替わらないまま一瞬で終わります。

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
  1 つの記述に一致したウィンドウは全て配置されるので、  
  枚数が増減するアプリ（IDE のプロジェクトウィンドウ等）も 1 行で書けます。

- **再キャプチャで手書き設定を失わない**  
  既存エントリに一致するウィンドウは、そのエントリのまま現在いる Space へ移されます。  
  手書きした `titlePattern` や `note` は再キャプチャ後も残ります。

- **無視リスト**  
  トップレベルの `ignore` に書いたウィンドウは、キャプチャで記録されず復元の候補からも外れます。  
  構成によらず無視したいものは `space_common.yaml` にまとめられます。

- **復元は Space を巡回しない**  
  非可視 Space のウィンドウも `hs.window.filter` から列挙するため、  
  移動が要らなければ画面を切り替えずに終わります。

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
* システム設定 > キーボード > キーボードショートカット > Mission Control で **「操作スペースを左/右に移動」ショートカットが有効**（Space をまたぐウィンドウ移動が必要な場合のみ使用。→ [Space をまたぐウィンドウ移動](#space-をまたぐウィンドウ移動) を参照）

# Installation

SpaceSaver は Hammerspoon の **Spoon**（`~/.hammerspoon/Spoons/SpaceSaver.spoon/`）として配置します。

### 1. yq をインストール

```bash
brew install yq
```

### 2. Spoon を配置

リポジトリを `SpaceSaver.spoon` という名前で `~/.hammerspoon/Spoons/` にクローンします（`init.lua` / `space_move.lua` / `space_mc.lua` / `space_order.lua` / `space_layout.svg` / スキーマ類を含みます）。

```bash
mkdir -p ~/.hammerspoon/Spoons
git clone git@github.com:piclane/SpaceSaver.git ~/.hammerspoon/Spoons/SpaceSaver.spoon
```

> エントリポイントは `init.lua` です。`space_move.lua` / `space_mc.lua` / `space_order.lua` / `space_layout.svg` / スキーマ類は Spoon バンドル内のリソースとして自動的に解決されます（手動コピー不要）。

### 3. `~/.hammerspoon/init.lua` に追記

```lua
hs.loadSpoon("SpaceSaver")
spoon.SpaceSaver:start()

-- 任意: ホットキーを割り当てる
-- spoon.SpaceSaver:bindHotkeys({
--   capture = {{"cmd", "alt", "ctrl"}, "c"},
--   restore = {{"cmd", "alt", "ctrl"}, "r"},
-- })

-- 任意: データ保存先を変更する（:start() の前に設定すること）
-- spoon.SpaceSaver.dataDir = os.getenv("HOME") .. "/Documents/SpaceSaver-data"
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
~/.hammerspoon/Spoons/SpaceSaver.spoon/capture-layout.sh
```

初回キャプチャで、データディレクトリ（デフォルト `~/.hammerspoon/`）に `space_layouts_1.yaml` が生成されます。

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
-- 現在の構成に対応するファイルの内容をコンソールに表示
spoon.SpaceSaver:dump()
```

復元を実行すると、配置したウィンドウごとの結果が Hammerspoon コンソールに出力されます。

```
配置 title=[LINE] bundleID=[jp.naver.line.mac] actualTitle=[LINE] -> screen=[62CF...] userSpace#1 spaceID=[2492] move=[none]
未配置 title=[OpenVPN Connect] bundleID=[org.openvpn.client.app] actualTitle=[] reason=[該当ウィンドウなし]
```

1 つの記述に複数のウィンドウが一致した場合は、その枚数ぶん `配置` 行が出ます。どのウィンドウかは `actualTitle=` で区別できます。`未配置` が出るのは、その記述に **1 枚も**一致しなかったときだけです。

`move=` は Space をまたぐ移動をどう処理したかを表します。

| 値 | 意味 |
|---|---|
| `none` | 既に目的の Space にいたので位置・サイズだけ合わせた |
| `native` | `hs.spaces.moveWindowToSpace` で移動できた |
| `drag` | タイトルバーを掴むドラッグ方式で移動した |
| `mc` | Mission Control 方式で移動した（→ [Mission Control 方式](#mission-control-方式)） |
| `failed` | 移動できず、位置・サイズだけ合わせた |
| `unsupported` | どの手段も無効と判明済みなので試さず、位置・サイズだけ合わせた |

フルスクリーン Space のエントリは `move=` ではなく `fullscreen=` が付きます。

| 値 | 意味 |
|---|---|
| `none` | 既に目的モニタでフルスクリーンだったので何もしなかった |
| `enter` | 同じモニタ上でフルスクリーン化した |
| `rescreen` | 別モニタのフルスクリーンを解除し、目的モニタで入れ直した |

### ホットキー（任意）

`bindHotkeys` でキャプチャ／復元にショートカットを割り当てられます。デフォルトの割り当てはありません（他の Spoon やシステムとの衝突を避けるため）。

```lua
spoon.SpaceSaver:bindHotkeys({
  capture = {{"cmd", "alt", "ctrl"}, "c"},  -- レイアウトをキャプチャ
  restore = {{"cmd", "alt", "ctrl"}, "r"},  -- レイアウトを復元
})
```

`:start()` の前後どちらで呼んでも構いません。

### データの保存先（任意）

`space_layouts_*.yaml` の保存先は `dataDir` で変更できます。デフォルトは `hs.configdir`（= `~/.hammerspoon/`）です。

```lua
-- :start() を呼ぶ前に設定すること
spoon.SpaceSaver.dataDir = os.getenv("HOME") .. "/Documents/SpaceSaver-data"
spoon.SpaceSaver:start()
```

> 保存先を変更した場合、既存の `space_layouts_*.yaml` は新しいディレクトリへ手動で移動してください。デフォルトのまま使う場合は移行不要です（`~/.hammerspoon/` に置かれた既存ファイルがそのまま使われます）。

### 取りこぼし時の拾い直し

**macOS は非可視 Space のウィンドウをアクセシビリティ API に出しません。** `hs.application:allWindows()` も `hs.window.allWindows()` も、そのウィンドウが表示されていない Space に居る間は返しません。`hs.window.get(id)` も `nil` になります。

復元は `hs.window.filter` を使ってこれを回避します。この filter は**一度見たウィンドウを、非可視 Space に移った後も保持し続ける**ためです。ただしキャッシュなので、Hammerspoon の起動・リロード直後は空です。そのとき別 Space に置かれていたウィンドウは、レイアウトに記述があっても「該当ウィンドウなし」になります。

埋める手段は、対象の Space を一度表示することだけです。既定で有効になっています。

```lua
-- 未評価のウィンドウがある Space を表示して拾う（デフォルト true）
spoon.SpaceSaver.rescanSpacesIfIncomplete = false
```

発動するのは、**まだ評価していないウィンドウを持つ Space があるとき**です。照合できない記述の有無では判断しません。1 つの記述には一致する全ウィンドウが入るので（→ [`windows[]`](#windowswindow-オブジェクト)）、「すべての記述が 1 枚以上一致した」ことは巡回を終える根拠にならないからです。未評価の Space に、同じ記述に一致する 2 枚目が居るかもしれません。

そのうえで表示する Space を次のように絞ります。

| 条件 | 扱い |
|---|---|
| 現在アクティブな Space | 飛ばす（そのウィンドウは既に列挙できている） |
| 既に評価したウィンドウしか無い Space | 飛ばす（表示しても新しい発見がない） |
| 照合できない記述を置くモニタ | 先に見る（取りこぼしの解消を早く見せるため） |

2 番目の判断には `hs.spaces.windowsForSpace` を使います。**この API は Space を表示しなくても所属ウィンドウの ID を返す**ため、表示する価値があるかを切り替える前に判断できます（ID から `hs.window` を復元することはできないので、実際に拾うには表示するしかありません）。

飛ばす条件を「表示済みの Space」ではなく「評価済みのウィンドウしか無い Space」にしているのは、**その Space に後から開かれたウィンドウを取りこぼさない**ためです。表示済みかどうかで判断すると、一度表示した Space に新しいウィンドウが増えても二度と見に行かず、そのウィンドウは永久に「該当ウィンドウなし」のままになります。

評価済みかどうかは Hammerspoon のリロードまで覚えています。したがって実際に巡回が走るのは、**リロード後の初回**と、**非可視 Space に新しいウィンドウが増えたとき**だけです。2 回目以降の復元は巡回 0 件で即座に配置に進みます。切り替えを一切挟みたくない場合は `false` にしてください（その場合、リロード直後は非可視 Space のウィンドウを取りこぼしたまま配置します）。`:start()` の前後どちらで設定しても構いません。

---

## Space をまたぐウィンドウ移動

macOS 15 (Sequoia) 以降、Hammerspoon が内部で使用していた private API が変更され、`hs.spaces.moveWindowToSpace` は**成功を返しながら実際にはウィンドウを移動しません**（[Hammerspoon issue #3698](https://github.com/Hammerspoon/hammerspoon/issues/3698)）。これは macOS 26 (Tahoe) でも解消していません。

SpaceSaver は OS バージョンでは分岐せず、**実際に移動できたかを `hs.spaces.windowSpaces` で検算**して手段を選びます。

1. ウィンドウが既に目的の Space にいる場合は、位置・サイズを合わせるだけで終わり（**Space は切り替わりません**）
2. 移動が必要な場合はまず `hs.spaces.moveWindowToSpace` を試し、実際に移動したか検算する
3. 移動していなければ**ドラッグ方式**に切り替える（遠い Space と、ドラッグ方式が効かないアプリは [Mission Control 方式](#mission-control-方式)）
   1. ウィンドウをアプリごと前面に出す（`focus`）
   2. タイトルバーの候補点をつかみ、数 px 動かして本当につかめたか確かめる
   3. ドラッグを保持したまま「操作スペースを左/右に移動」ショートカットを送出し、目的の Space まで 1 つずつ移動する
   4. マウスを放してウィンドウを正確な位置・サイズに補正する

段数を数えるときは**フルスクリーンの Space を除きます**。ドラッグ中のウィンドウはフルスクリーンの Space に置けないため、macOS はそこを飛ばして次へ進めます。全 Space で数えると、間に挟まったフルスクリーンのぶんだけ行き過ぎます。

数えた段数が 0 なら**掴みません**。別スクリーンのウィンドウは `setFrame` で目的のモニタへ寄せてから扱いますが、寄せた先で表示中の Space がそのまま目的地であれば、それで移動は済んでいます（Space が 1 つしかないモニタでは必ずこうなります）。ここで掴むと、動かす必要のないウィンドウを掴んで揺らすだけになります。

`hs.spaces.moveWindowToSpace` が無効という判定は Hammerspoon のセッション内で保持されるため、検算の待ち時間がかかるのは最初の 1 ウィンドウだけです。2 件目以降は直接ドラッグ方式に進みます。

多くの場合、復元で移動が必要なウィンドウはごく一部です。移動が不要なウィンドウしかなければ、**復元中に Space は一度も切り替わりません**。

### ウィンドウの掴み方

ドラッグ方式で最初に決めるのは、ウィンドウのどこを掴むかです。ここは固定のオフセットでは決まりません。

| 掴む位置 | 起きること |
|---|---|
| 左端 (`x + 5`) | リサイズ枠に当たり、ウィンドウを横に伸縮させるだけになる |
| 上端から 1px | 同じくリサイズ枠 |
| 上端の中央 | タブ帯を持つアプリではタブを掴む。1px のドラッグはタブ操作として扱われ、ウィンドウは動かない |

とくに Google Chrome が厄介です。Chrome のタブはウィンドウ上端 0px からタブ帯の全高を占めるため、**タブの上には掴める余白がありません**。しかもタブは 4〜5 枚を超えると水平中央まで届くので、上端中央を掴む方式はほぼ確実に外れます。掴めるのは信号ボタンの上、タブ帯の左内側（左端から 86px ほど）だけです。

そこで SpaceSaver は、**信号ボタン（閉じる・最小化・全画面）の実測位置**を基準に候補点を組み立てます。この 3 つは `AXWindow` の標準属性（`AXCloseButton` / `AXMinimizeButton` / `AXZoomButton`）なので、タイトルバーを自前で描くアプリでも位置が取れます。

| 候補 | 狙い |
|---|---|
| ボタンの真上 | ボタンとウィンドウ上端の間。多くのアプリでウィンドウ本体 |
| ボタンとボタンの隙間 | ボタンの高さでも、間はウィンドウ本体 |
| ボタン群の右 (+8, +20px) | タブ帯やツールバーが始まるより手前 |
| ボタン群の左・下 | 上記が全滅したときの保険 |

いずれもタブ帯が始まるより左なので、Chrome のようにタブが上端いっぱいを占めるアプリでもタブを掴みません。ボタン自体の矩形は候補から外れるため、掴んだつもりでウィンドウを閉じてしまうこともありません。

信号ボタンを取れなかったウィンドウに限り、左端から 40〜100px の固定候補へ落とします。**信号ボタンが取れているときはこの保険を使いません**。ボタン群より右はタブ帯に入りうるため、掴み損ねるだけでなくタブを掴んで動かしてしまうからです。

当たり判定（`hs.axuielement.systemElementAtPosition`）は 2 つの用途に絞って使います。**候補点が本当にそのウィンドウのものか**（`AXWindow` の祖先まで辿ってウィンドウ ID で照合）と、**押してはいけない要素でないか**（ボタン、タブ、プロキシアイコンなど）の確認です。

#### つかめたかどうかは、その場では判定しない

掴んだ直後に「掴めたか」を見分ける手段はありません。当たり判定では決められず（ウィンドウと同じ矩形を返しながら掴めない点も、別の矩形を返しながら掴める点もあります）、**試しに動かしてフレームを読む方法も当てになりません**。実測では、ウィンドウが実際に動いてもフレームに反映されないアプリがありました。Chrome は同じ点・同じウィンドウでも、マウスを放すまで新しい位置を返さないことがあります。これを失敗と読むと、掴めているのに掴めなかったと誤判定します。しかも試し掴みはタブを動かすなどの副作用を残します。

そこで SpaceSaver は判定を行いません。候補点を1つ選んで掴み、そのまま Space を移動し、**結果を `hs.spaces.windowSpaces` で検算**します。失敗したら次の試行では別の候補点から始めます。掴めた点は bundleID ごとに覚え、次のウィンドウから最初に試します。

#### ドラッグ量には下限がある

ウィンドウは、掴んですぐには動き出しません。実測では**どのアプリも 10px 手前では 1px も動かず**、そこを超えてから追随を始めます。そのため 1px のドラッグでは把持が成立しません。SpaceSaver は余裕を見て 24px 動かしてからショートカットを送ります。

#### 前面に出してからつかむ

つかむ前に、ウィンドウを**アプリごと前面に出します**（`hs.window:focus()`）。`raise()` ではアプリをまたぐ重なり順が変わらず、別アプリのウィンドウに覆われたままになります。覆われた状態では当たり判定も実際のクリックも覆っている側に吸われるため、**覆っているウィンドウのほうが Space を渡っていき、目的のウィンドウは取り残されます**。

同じ大きさに広げたウィンドウどうしが重なっている場合、矩形の一致だけでは自分か他人かを見分けられません。ウィンドウ ID で照合するのはこのためです。

つかめない位置をつかむと、Space だけが切り替わってウィンドウが取り残されます。そうした場合はコンソールに次のように出ます。

```
SpaceSaver(space_move): com.example.app をドラッグで移動できません（Space の切替について来ない, 把持点=+65,+6）[1/3]
```

このときは、そのまま [Mission Control 方式](#mission-control-方式) に切り替えて移動をやり直します。判定はアプリ単位なので、1 つのアプリが失敗しても他のアプリには影響しません。

### Mission Control 方式

**掴めているのに Space の切替について来ない**アプリがあります。実測では Excel と LINE がこれにあたり、ウィンドウは掴めていて（マウスに合わせてフレームが動く）、それでもショートカットで Space を切り替えるとウィンドウだけ取り残されます。掴む位置・ドラッグ量・切替中の動かし方を変えても結果は同じでした。ドラッグをアプリ自身が処理していて、ウィンドウサーバ側に「ドラッグ中のウィンドウ」が無いためと思われます。

同じ画面・同じ経路で Chrome・Sublime Text・メモは成功するので、環境ではなくアプリの実装差です。

そうしたアプリのために、SpaceSaver は **Mission Control を開き、ウィンドウのサムネイルを Space のサムネイルへドラッグする**手段を持っています。人が手でやる操作をそのままなぞるもので、処理するのは Dock なので、アプリ側の実装差を受けません。

#### 使い分け

| 条件 | 方式 |
|---|---|
| 目的の Space まで 3 段以上離れている | Mission Control 方式 |
| ドラッグ方式が効かないと分かったアプリ | Mission Control 方式 |
| それ以外 | ドラッグ方式 |

ドラッグ方式は 1 Space ずつ送るため、離れているほど時間がかかります（1 段あたり約 0.6 秒）。Mission Control 方式は**距離によらず 1.8 秒前後**で終わるので、3 段以上離れていれば後者のほうが速くなります。

ドラッグ方式が効かないアプリは、**最初の失敗の時点で**切り替えます。失敗を数えてから切り替えたのでは、そのアプリのウィンドウを移すたびに無駄なドラッグを繰り返すことになるためです。

#### つまずいた点

| 症状 | 原因 |
|---|---|
| サムネイルを掴めない | `hs.mouse.absolutePosition` はカーソルをワープさせるだけで `mouseMoved` を出さない。ホバーが付かず、掴める状態にならない。枠の外から中へ `mouseMoved` を出しながら入る |
| 掴んだつもりで空振りする | AX ツリーは Mission Control のアニメーション途中で既に埋まる。子要素の有無で開き終わりを判断すると、まだ動いているサムネイルを掴もうとする。座標が 2 回続けて同じになるまで待つ |
| 新しいフルスクリーン Space ができてしまう | ドラッグ中はカーソルの位置に「新規フルスクリーン用の仮枠」が差し込まれ、Space サムネイルの番号が 1 つずれる。しかも仮枠はカーソルと一緒に動く。番号ではなく**名前**で狙う |

### フルスクリーン Space の並び順

新しいフルスクリーン Space は、元ウィンドウがどの Space に居たかに関係なく **必ずその画面の末尾** に作られます。`hs.spaces` に並び替えの API はなく、Mission Control 上の Space サムネイル（`AXButton`）も `AXPress` と `AXRemoveDesktop` しか持ちません。

そこで SpaceSaver は、サムネイルの `AXFrame` を読んでマウスでドラッグします。

```lua
-- 並べ替えを行わない場合（デフォルトは true）
spoon.SpaceSaver.restoreFullscreenSpaceOrder = false
```

実装上の注意が 2 つあります。

- **Space バーはカーソルが載るまで小さいピル表示のまま**で、その状態の `AXFrame` は別モニタの座標を返すことがあります。対象モニタの上端へカーソルを移してから読み、座標が 2 回続けて同じかつ対象モニタの矩形内に収まることを確かめてから掴みます
- **着地位置はドラッグ方向で 1 ずれます**。右へ動かすとつまみ上げたぶん後続が左へ詰まるため、1 つ先の位置へ落とします

並びが既に合っていれば Mission Control は開きません。1 回の並べ替えに 5 秒ほどかかります。

目標の位置は、レイアウトの Space 配列そのままではなく**実際に作られる Space 列の通し番号**で決めます。`type: fullscreen` の記述に n 枚一致すれば n 個のフルスクリーン Space ができ、レイアウト上の同じ位置に連続して並びます。1 枚も一致しなかった記述は Space を作らないので位置を消費せず、後続のフルスクリーン Space が前に詰まります。

### フルスクリーンのウィンドウ

`type: fullscreen` の Space に置かれたウィンドウは、上のドラッグ方式ではなく `setFullScreen` で処理します。`setFullScreen(true)` は「ウィンドウが今いるモニタ」で全画面化するため、目的のモニタに居ない場合は次の順で入れ直します。

1. 全画面のままでは `setFrame` でモニタを移せないので、いったん `setFullScreen(false)` で解除する
2. YAML の `frame` で目的モニタへ寄せる（`frame` が無ければモニタの矩形で代用）
3. `setFullScreen(true)` で全画面化する

各段でアニメーションの収束を待つため 1 ウィンドウあたり 3 秒ほどかかり、その間はそのモニタの Space が切り替わります。既に目的のモニタで全画面なら何もしません。

1 つの記述に複数のウィンドウが一致した場合は、その全てを全画面化します。枚数ぶん時間がかかる点に注意してください。

### ショートカットの設定

ドラッグ方式は macOS のショートカットで Space を切り替えるため、その割当が必要です。既定では **`com.apple.symbolichotkeys` から実際の割当を自動検出**するので、通常は設定不要です。テンキー割当（例: `Ctrl+Alt+Cmd+テンキー7/9`）にも対応します。

自動検出がうまくいかない場合のみ、`spaceSwitchHotkeys` で明示します。**`:start()` の前に設定すること**：

```lua
hs.loadSpoon("SpaceSaver")

spoon.SpaceSaver.spaceSwitchHotkeys = {
  left  = {{"ctrl", "alt", "cmd"}, "pad7"},   -- 左の Space へ移動
  right = {{"ctrl", "alt", "cmd"}, "pad9"},   -- 右の Space へ移動
}

spoon.SpaceSaver:start()
```

修飾キーには `"ctrl"`, `"alt"`, `"cmd"`, `"shift"`, `"fn"` が使えます（`"control"` / `"option"` / `"command"` とも書けます）。キー名は [Hammerspoon の `hs.keycodes.map`](https://www.hammerspoon.org/docs/hs.keycodes.html) の値（`"f1"`〜`"f20"`, `"left"`, `"right"`, `"pad7"` など）に準じます。

#### macOS 側のショートカット確認方法

**システム設定 > キーボード > キーボードショートカット > Mission Control** を開き、「操作スペースを左に移動」「操作スペースを右に移動」の設定を確認します。

> **ショートカットが無効になっている場合**は、チェックボックスをオンにして有効化してください。ドラッグ方式は macOS がこのショートカットを処理することで Space を切り替えるため、無効だと移動できません。

### 既知の制限

| 制限 | 内容 |
|---|---|
| 速度 | 移動が必要なウィンドウ 1 つあたり数百 ms〜数秒。移動不要なウィンドウは瞬時 |
| マウスカーソル | ドラッグ方式が動いている間だけカーソルが画面上を動く |
| フォーカス | 掴む前にウィンドウを前面に出すため、移動したウィンドウのアプリが最前面になる |
| 隣接 Space のみ移動可 | 目的の Space が離れているほど時間がかかる（途中の Space を 1 つずつ通過する） |
| cross-screen 移動 | 別スクリーン上のウィンドウはベストエフォート（`setFrame` で寄せてからドラッグ） |
| 掴めないアプリ | ドラッグ方式が効かないアプリは Mission Control 方式に切り替わる。その間 Mission Control が開閉する（→ [Mission Control 方式](#mission-control-方式)） |

# Configuration Reference

キャプチャで生成される `space_layouts_<n>.yaml` のスキーマ詳細です。  
保存時、YAML 先頭の `$schema` には Spoon バンドル内 `space_layouts.schema.json` への**絶対パス**が自動で書き込まれるため、VS Code（YAML 拡張）で補完・バリデーションがそのまま効きます。

### ファイル全体の構造

```yaml
# yaml-language-server: $schema=/Users/you/.hammerspoon/Spoons/SpaceSaver.spoon/space_layouts.schema.json
apiVersion: v1          # 固定値
kind: SpaceLayouts      # 固定値
ignore: [...]           # 記録も復元もしないウィンドウの規則（任意）
screens:                # モニタ UUID → screen オブジェクト のマップ
  "<UUID>":
    metadata: ...
    spaces: [...]
```

| フィールド | 型 | 説明 |
|---|---|---|
| `apiVersion` | `"v1"` | 固定。将来のバージョン互換のために保持。 |
| `kind` | `"SpaceLayouts"` | 固定。 |
| `ignore` | array | キャプチャ時に記録せず、復元時のウィンドウ候補からも除外する規則。省略可。 |
| `screens` | object | キーがモニタの UUID（`hs.screen:getUUID()`）。この UUID の集合がモニタ構成の識別子になる。 |

> **ファイルの選択ロジック**：データディレクトリ（デフォルト `~/.hammerspoon/`）の `space_layouts_*.yaml` を順に読み込み、`screens` のキー集合が現在接続中のモニタ UUID 集合と一致するファイルが選ばれます。ファイル名は単なるラベルであり、照合には使用しません。

---

### `ignore[]`（無視するウィンドウ）

記録も復元もしたくないウィンドウを宣言します。デベロッパーツールのように毎回位置が変わるウィンドウや、常駐アプリのオーバーレイを締め出すのに使います。

```yaml
ignore:
  - bundleID: "com.google.Chrome"
    titlePattern: "^DevTools"
    note: "毎回位置が変わるので記録しない"
  - bundleID: "pro.betterdisplay.BetterDisplay"   # title 系を省略 = そのアプリの全ウィンドウ
  - titlePattern: "^Picture in Picture$"          # bundleID を省略 = 全アプリ横断
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `bundleID` | string | — | アプリの Bundle ID。省略すると全アプリが対象。 |
| `title` | string | — | ウィンドウタイトルの完全一致。 |
| `titlePattern` | string | — | ウィンドウタイトルの Lua パターン。`title` より優先。 |
| `note` | string | — | 無視する理由のメモ。動作には影響しない。 |

`bundleID` / `title` / `titlePattern` のうち**書いたものすべてに一致**したウィンドウが無視されます（AND）。最低 1 つは必須です。

**効果は 2 つあります**：

1. **キャプチャ時**：そのウィンドウを記録しません。既にレイアウトに書かれているエントリも、`ignore` に一致すれば再キャプチャで削除されます。不要になったエントリを掃除する手段になります。
2. **復元時**：ウィンドウ候補から除外します。除外しないと、`.*` のような広く当たるパターンに一致して、無視したはずのウィンドウが別のエントリに割り当てられ、意図しない位置へ動かされます。

モニタ構成によらず常に無視したいものは、レイアウトファイルごとに書かず [共通設定ファイル](#共通設定ファイルspace_commonyaml) にまとめられます。

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
| `frame` | frame | — | ウィンドウの位置とサイズ。省略すると復元時にリサイズしない。複数一致した場合は全ウィンドウに同じ値を適用する。 |
| `note` | string | — | メモ。動作には影響せず、再キャプチャしても保持される。 |

**1 つの記述は、一致したウィンドウを全て配置します**（1 対 n）。`titlePattern: '.*'` なら、そのアプリのウィンドウ全部が対象です。`title` の完全一致でも、同じタイトルのウィンドウが複数あればすべて動きます。

**ウィンドウ照合のルール**（復元時）：

1. `ignore` に一致するウィンドウを候補から除外する
2. `bundleID` が一致するウィンドウをプールとして絞り込む
3. `titlePattern` が指定されていれば `string.find(title, titlePattern)` で照合
4. `titlePattern` がなければ `title` と完全一致で照合
5. 3 または 4 に一致したウィンドウを**全て**その記述に割り当てる

`bundleID` だけが一致するウィンドウは動かしません。動かすと、パターンを書き損じたウィンドウが無関係な記述に吸い付き、意図しない位置へ運ばれてしまいます。

**行き先の決め方**：1 つのウィンドウが複数の記述に当たるとき、次の優先順位で入る先を決めます。

1. **パターンの自由度が低い（具体的な）記述**を優先する
2. 同じなら、**まだ割り当てが少ない記述**に入れる
3. それも同じなら YAML の記述順で先にあるほうに入れる

```yaml
# この2つが同じアプリを指す場合
- bundleID: "com.jetbrains.intellij"
  titlePattern: '.*'                    # 名指しに取られた残り全部が入る
- bundleID: "com.jetbrains.intellij"
  titlePattern: "^SpaceSaver.spoon – "  # 特定のウィンドウを名指し → こちらを優先
```

1 が無いと、`.*` のように広く当たるパターンが名指しの記述の取り分まで飲み込んでしまいます。自由度は、**パターンが必ず一致を要求するリテラル文字の数**で測ります（`^` `$` のアンカーも加点）。`.*` は 0、`^SpaceSaver.spoon – ` は 21 のようになります。`titlePattern` を持たない `title` の完全一致は、どのパターンよりも優先されます。

2 が必要なのは、キャプチャが 1 記述 1 ウィンドウで記録するためです。同じタイトルのウィンドウが別々の Space にあると、同じ内容の記述が Space ごとにできます。先着順で入れると全部が先頭の記述へ寄ってしまい、キャプチャした配置を復元できません。

> 画面の処理順は `screens` の UUID 昇順に固定されています。順序が変わると自由度が同点の記述の取り分が変わり、復元結果が実行ごとにぶれるためです。

**再キャプチャ時の照合**は上の 1〜4 と同じで、こちらも `bundleID` だけの一致は使いません。ただし割り当ては 1 対 1 です。実ウィンドウ 1 枚が既存エントリを 1 つ消費し、そのエントリのまま現在いる Space へ移され、`frame` だけ実測値に更新されます。1 つのエントリを複数のウィンドウで共有すると、どのウィンドウの `frame` を書き戻すか決められないためです。パターンに一致するウィンドウが 2 枚あれば、2 枚目は `title` 完全一致の新しいエントリとして記録されます。

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
# yaml-language-server: $schema=/Users/you/.hammerspoon/Spoons/SpaceSaver.spoon/space_layouts.schema.json
apiVersion: v1
kind: SpaceLayouts

# 記録も復元もしないウィンドウ
ignore:
  - bundleID: "com.google.Chrome"
    titlePattern: "^DevTools"
    note: "毎回位置が変わるので記録しない"
  - bundleID: "pro.betterdisplay.BetterDisplay"   # そのアプリの全ウィンドウ

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
            note: "検索用に常に開いているウィンドウ"   # 再キャプチャしても残る
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

---

## 共通設定ファイル（space_common.yaml）

モニタ構成によらず効かせたい設定を、データディレクトリの `space_common.yaml` に 1 つだけ置けます。現在のキーは `ignore` だけです。**このファイルは任意で、無ければ従来どおり動きます**。

```yaml
# yaml-language-server: $schema=/Users/you/.hammerspoon/Spoons/SpaceSaver.spoon/space_common.schema.json
apiVersion: v1          # 固定値
kind: SpaceCommon       # 固定値

ignore:
  - bundleID: "com.apple.finder"
    note: "どの構成でもデスクトップは記録しない"
  - titlePattern: "^Picture in Picture$"
    note: "PiP はどのアプリでも記録しない"
```

| フィールド | 型 | 説明 |
|---|---|---|
| `apiVersion` | `"v1"` | 固定。 |
| `kind` | `"SpaceCommon"` | 固定。レイアウトファイルと区別するために使う。 |
| `ignore` | array | 全構成に適用する無視規則。書式は [`ignore[]`](#ignore無視するウィンドウ) と同一。省略可。 |

規則の書式がレイアウトファイルと同じなので、既存の `ignore` から行をそのまま移せます。

### 合成のしかた

共通ファイルの `ignore` と、選ばれたレイアウトファイルの `ignore` を**連結**して使います。どちらか一方に一致すれば無視されるため、共通には構成非依存の規則を、レイアウトファイルにはその構成だけの規則を置けます。

`spoon.SpaceSaver:dump()` を実行すると、共通ファイルの内容と、連結後の「有効な ignore」が確認できます。

### レイアウトファイルへは書き戻しません

再キャプチャでレイアウトファイルを保存するとき、`ignore` にはそのファイル自身の規則だけを書きます。共通の規則を書き戻すと全レイアウトファイルに複製され、共通ファイルを直しても古い複製が残ってしまうためです。

### 注意

- ファイル名を `space_layouts_` で始めないでください。レイアウトファイルの走査パターンに掛かり、毎回読み込まれます
- `apiVersion` / `kind` が違う、`ignore` が配列でない、といった場合はコンソールに理由を出したうえでファイルを無視します（レイアウトファイルの `ignore` だけで動作します）
- yq が無い環境では `space_common.json` を読みます

# Note

- キャプチャはアクティブになった Space のウィンドウのみ正確に取得できます。Mission Control が一瞬表示されますが、**システム設定 > アクセシビリティ > 「視差効果を減らす」** を有効にすると目立たなくなります。
- ウィンドウの照合は `bundleID + タイトル`（または `titlePattern`）のベストエフォートです。タイトルが完全に一意でないアプリでは意図しないウィンドウと照合されることがあります。
- **1 つの記述には、一致したウィンドウが全て入ります**（→ [`windows[]`](#windowswindow-オブジェクト)）。`titlePattern: '.*'` はそのアプリのウィンドウ全部を動かします。記述の枚数ぶんだけ動かしたい場合は、パターンを具体的に書いてください。
- **`bundleID` だけが一致するウィンドウは動きません。** `title` の完全一致で記録されたエントリは、アプリがタイトルを変えると照合できなくなり、そのウィンドウは配置対象から外れます（コンソールに `未配置 ... reason=[該当ウィンドウなし]` が出ます）。タイトルが変わるアプリでは `titlePattern` に書き換えてください。
- 復元は Space の数を YAML に合わせます。足りなければ追加し、多すぎれば末尾から削除します。ただし macOS の制約で 1 画面につき user Space は最低 1 つ残ります。削除される Space にウィンドウが残っていると、macOS がそれらを隣の Space へ移すため配置が崩れることがあります。
- フルスクリーンのウィンドウは、YAML に記録されたモニタで全画面化されます。別のモニタで全画面になっていた場合は、いったん解除してから目的のモニタで入れ直します（アニメーションを挟むため 1 ウィンドウあたり 3 秒ほどかかります）。既に正しいモニタで全画面なら何もしません。
- フルスクリーン Space の並び順も復元します。新しいフルスクリーン Space は macOS が必ず画面の末尾に作るため、そのままでは順番が合いません。Mission Control を開いてサムネイルをドラッグし、YAML の位置へ移動させます。並びが既に合っていれば Mission Control は開きません。
- 再キャプチャは既存のエントリを引き継ぎます。`bundleID` と `title`／`titlePattern` が一致するウィンドウは、そのエントリのまま**現在いる Space** へ移され、`frame` だけ実測値に更新されます。手書きした `titlePattern` や `note` は失われません。どのウィンドウにも一致しなかったエントリ（アプリ未起動など）は元の位置に残るので、不要になったら手で削除するか `ignore` に書いてください。
  - 復元と違い、キャプチャの割り当ては 1 対 1 です。1 つのエントリを複数のウィンドウで共有すると、どのウィンドウの `frame` を書き戻すか決められないためです。`titlePattern` に 2 枚以上一致する場合、2 枚目からは `title` 完全一致の新しいエントリとして記録されます。
- 再キャプチャすると `screens.<UUID>.metadata.name` と `metadata.frame` は実モニタ情報で上書きされます。ユーザーが追加した他のメタデータキーは保持されます。
- 復元では Space を巡回せず、非可視 Space のウィンドウも `hs.window.filter` から列挙します。Hammerspoon のリロード直後だけキャッシュが揃わず取りこぼすことがあります（Usage の「取りこぼし時の巡回」を参照）。
- Space をまたぐ移動が必要なウィンドウがある場合のみ、その間だけマウスカーソルが動き Space が切り替わります（→ [Space をまたぐウィンドウ移動](#space-をまたぐウィンドウ移動)）。

# Author

* piclane

# License

SpaceSaver is under [MIT license](https://en.wikipedia.org/wiki/MIT_License).
