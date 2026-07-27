--[[
  SpaceSaver (init.lua) — Hammerspoon Spoon
  ----------------------------------------------------------------
  物理モニタ「構成」ごとに独立したYAMLファイルで
  macOS Spacesレイアウトを保存・復元するHammerspoon Spoon。

  ファイル形式: <dataDir>/space_layouts_<n>.yaml (Kubernetes スタイル)
                dataDir のデフォルトは ~/.hammerspoon (hs.configdir)
  スキーマ:     Spoon バンドル内の space_layouts.schema.json
                （保存YAMLの $schema には絶対パスを自動付与）

  インストール:
    1. このフォルダを ~/.hammerspoon/Spoons/SpaceSaver.spoon/ に置く
    2. ~/.hammerspoon/init.lua に以下を追記:
         hs.loadSpoon("SpaceSaver")
         spoon.SpaceSaver:start()
    3. Hammerspoonをリロード (メニューバー > Reload Config)

  （任意）ホットキー:
         spoon.SpaceSaver:bindHotkeys({
           capture = {{"cmd","alt","ctrl"}, "c"},
           restore = {{"cmd","alt","ctrl"}, "r"},
         })

  （任意）データ保存先の変更（:start() の前に設定すること）:
         spoon.SpaceSaver.dataDir = os.getenv("HOME") .. "/Documents/SpaceSaver-data"

  キャプチャ（手動）:
    - メニューバーの ⊞ > レイアウトをキャプチャ
    - open -g "hammerspoon://space-capture"
    - ~/.hammerspoon/Spoons/SpaceSaver.spoon/capture-layout.sh

  復元（自動）:
    - モニタ構成変更時（dock脱着など）に自動実行
    - メニューバーの 再リストア で手動実行も可

  前提条件:
    - システム設定 > デスクトップとDock >
      「ディスプレイごとに異なるSpaceを表示」を有効にしておくこと
    - Hammerspoonにアクセシビリティ権限を許可しておくこと
    - yq (https://github.com/mikefarah/yq) v4 が
      /opt/homebrew/bin/yq または PATH に存在すること
    - （推奨）「視差効果を減らす」を有効にするとキャプチャ中の画面切替が目立たなくなる
    - システム設定 > キーボード > キーボードショートカット > Mission Control >
      「操作スペースを左/右に移動」ショートカットが有効であること
      （Spaceをまたぐ移動が必要な場合のみ使用。割当はOS設定から自動検出する）

  既知の制限:
    - Luaパターン照合（完全なPCREではない）
    - フルスクリーンSpaceの並び順も復元する。新しいフルスクリーンSpaceは
      必ず画面の末尾に作られるため、Mission Controlでサムネイルをドラッグして直す
      （restoreFullscreenSpaceOrder=false で無効化できる）
    - フルスクリーンのウィンドウは記録されたモニタで全画面化する。
      別モニタで全画面だった場合は解除→移動→全画面化で入れ直す（数秒かかる）
    - 復元はSpace数をYAMLに合わせる（不足なら追加、余剰なら末尾から削除）。
      ただしmacOSの制約で1画面につきuser Spaceは最低1つ残る
    - キャプチャ中はMission Controlが各Spaceぶん切り替わる
    - 再キャプチャでscreen.metadata.name/frameは実情報で上書き（ユーザーが追加した他キーは温存）
    - 再キャプチャは既存エントリを引き継ぐ。title/titlePattern が一致するウィンドウは
      そのエントリのまま現在のSpaceへ移し、frameだけ更新する。
      一致しなかった既存エントリは元の位置に残る（ignoreに一致するものは削除）
    - yq不在時はJSONフォールバック（space_layouts_<n>.json）で動作
    - Spaceをまたぐ移動が必要なウィンドウはドラッグ方式で移動するため、
      その間だけマウスカーソルが動き、Spaceが切り替わる
      （hs.spaces.moveWindowToSpace は macOS 15 以降、成功を返しつつ移動しない）
--]]

local obj = {}
obj.__index = obj

-- Spoon メタデータ
obj.name     = "SpaceSaver"
obj.version  = "3.0.0"
obj.author   = "piclane"
obj.homepage = "https://github.com/piclane/SpaceSaver"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

-- space_layouts_*.yaml の保存先。デフォルトは hs.configdir (~/.hammerspoon)。
-- :start() の前に上書き可能。
obj.dataDir  = hs.configdir

-- ドラッグ方式 Space 移動で送出するショートカット。
-- 既定の nil では macOS「システム設定 > キーボード > キーボードショートカット >
--   Mission Control > 操作スペースを左/右に移動」の割当を自動検出する。
-- 自動検出が効かない環境でのみ、bindHotkeys と同じ {{修飾キー...}, キー} 形式で明示する。
-- 例:
--   spoon.SpaceSaver.spaceSwitchHotkeys = {
--     left  = {{"ctrl","alt","cmd"}, "pad7"},
--     right = {{"ctrl","alt","cmd"}, "pad9"},
--   }
obj.spaceSwitchHotkeys = nil

-- 照合できないウィンドウがあったとき、全 Space を巡回して取り直すか。
-- 通常は hs.window.filter が非可視 Space のウィンドウも保持しているため巡回は不要で、
-- 既定では巡回しない（有効にすると Space 数だけ画面が切り替わり数十秒かかる）。
-- Hammerspoon をリロードした直後は filter のキャッシュが揃っておらず、
-- 同一アプリの2枚目以降のウィンドウを取りこぼすことがある。
-- そこまで確実に復元したい場合のみ true にする。
obj.rescanSpacesIfIncomplete = false

-- フルスクリーン Space をレイアウトどおりの位置へ並べ替えるか。
-- Mission Control を開いてサムネイルをドラッグするため、
-- 並びがずれているときだけ動くとはいえ数秒かかり画面上でも目立つ。
obj.restoreFullscreenSpaceOrder = true

-- Space 移動モジュール（space_move.lua）を読み込む
local spaceMove  = dofile(hs.spoons.resourcePath("space_move.lua"))
-- Space 並び替えモジュール（space_order.lua）を読み込む
local spaceOrder = dofile(hs.spoons.resourcePath("space_order.lua"))

-- ============================================================
-- 設定定数
-- ============================================================

local YQ_DEFAULT = "/opt/homebrew/bin/yq"

local SCREEN_SETTLE  = 2.0   -- 秒: モニター変化後、復元開始までのデバウンス
local RESTORE_DELAY  = 1.0   -- 秒: Space追加/削除後、ウィンドウ移動までの待機
local CAPTURE_SETTLE = 0.6   -- 秒: gotoSpace後、ウィンドウ取得までの待機
local MC_STEP_DELAY  = 0.6   -- 秒: Space追加/削除(Mission Control操作)の各ステップ間の待機

-- 各YAMLファイルの先頭に付与するヘッダを返す
-- "screens:" は yq の変換出力がそのまま続くので、ここには含めない
-- $schema は Spoon バンドル内スキーマの絶対パス（エディタ検証用）
local function yamlHeader()
  local schemaPath = hs.spoons.resourcePath("space_layouts.schema.json")
  return "# yaml-language-server: $schema=" .. schemaPath .. "\n" ..
         "apiVersion: v1\n" ..
         "kind: SpaceLayouts\n"
end

-- ============================================================
-- 内部状態
-- ============================================================

local trackedSignature = nil   -- 前回のscreenSignature（変化検知用）
local busy             = false -- キャプチャ中フラグ（多重起動防止）
local screenWatcher    = nil
local screenTimer      = nil
local menubar          = nil
local windowFilter     = nil   -- 非可視Spaceも含むウィンドウ列挙用（遅延生成）

-- ============================================================
-- ユーティリティ
-- ============================================================

-- hs.timer.doAfter は戻り値を保持しないとタイマーが GC され、
-- コールバックが呼ばれないままキャプチャ・復元が途中で止まる。発火するまで参照を持つ。
local pendingTimers = {}

local function later(delay, fn)
  local t
  t = hs.timer.doAfter(delay, function()
    pendingTimers[t] = nil
    fn()
  end)
  pendingTimers[t] = true
  return t
end

-- yq バイナリのパスを返す（見つからなければnil）
local function yqBin()
  if hs.fs.attributes(YQ_DEFAULT) then return YQ_DEFAULT end
  local r, ok = hs.execute("which yq 2>/dev/null")
  if ok and r and r:match("%S") then return r:gsub("%s+$", "") end
  return nil
end

-- シェル用のシングルクォート
local function sq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- パスのbasename
local function basename(path)
  return path:match("[^/]+$") or path
end

-- ============================================================
-- 永続化（構成ごとファイル）
-- ============================================================

-- 使用する拡張子（yqありならyaml、なければjson）
local function configExt()
  return yqBin() and "yaml" or "json"
end

-- YAMLまたはJSONファイルを読み込んでデコードする（失敗時nil）
local function loadConfigFile(path)
  local ext = path:match("%.([^%.]+)$")
  if ext == "yaml" then
    local yq = yqBin()
    if not yq then return nil end
    local out, ok = hs.execute(
      string.format("%s -o=json -p=yaml %s 2>/dev/null", sq(yq), sq(path)))
    if ok and out and out:match("%S") then
      local succ, data = pcall(hs.json.decode, out)
      -- apiVersion / kind でフォーマット検証
      if succ and type(data) == "table"
         and data.apiVersion == "v1"
         and data.kind == "SpaceLayouts"
         and type(data.screens) == "table" then
        return data
      end
    end
  elseif ext == "json" then
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    local ok, data = pcall(hs.json.decode, s)
    if ok and type(data) == "table" then return data end
  end
  return nil
end

-- space_layouts_*.{yaml|json} のパス一覧をソートして返す
local function listConfigFiles()
  local ext = configExt()
  local pat = "^space_layouts_.+%." .. ext .. "$"
  local files = {}
  pcall(function()
    for name in hs.fs.dir(obj.dataDir) do
      if name:match(pat) then
        table.insert(files, obj.dataDir .. "/" .. name)
      end
    end
  end)
  table.sort(files)
  return files
end

-- data.screens のキーを集合（{uuid=true}）で返す
local function screensSetOf(data)
  local set = {}
  if data and type(data.screens) == "table" then
    for uuid in pairs(data.screens) do set[uuid] = true end
  end
  return set
end

-- 現在のscreen集合(set)に一致するファイルを探す
-- 一致したら (path, data) を返す。なければ (nil, nil)
local function findConfigFile(set)
  local setCount = 0
  for _ in pairs(set) do setCount = setCount + 1 end

  for _, path in ipairs(listConfigFiles()) do
    local data = loadConfigFile(path)
    if data then
      local n, matched = 0, true
      for uuid in pairs(screensSetOf(data)) do
        if not set[uuid] then matched = false; break end
        n = n + 1
      end
      if matched and n == setCount then return path, data end
    end
  end
  return nil, nil
end

-- 未使用の space_layouts_<n>.{yaml|json} パスを返す
local function nextConfigFilePath()
  local ext = configExt()
  local i = 1
  while hs.fs.attributes(obj.dataDir .. "/space_layouts_" .. i .. "." .. ext) do
    i = i + 1
  end
  return obj.dataDir .. "/space_layouts_" .. i .. "." .. ext
end

-- screens テーブルを指定パスに保存する（成功=true）
-- ignoreRules は既存ファイルから引き継いだ無視リスト（空なら書き出さない）
local function saveConfigFile(path, screens, ignoreRules)
  local payload = { screens = screens }
  if type(ignoreRules) == "table" and #ignoreRules > 0 then
    payload.ignore = ignoreRules
  end
  local ok, encoded = pcall(hs.json.encode, payload, true)
  if not ok then
    hs.alert.show("SpaceSaver: エンコード失敗: " .. tostring(encoded))
    return false
  end
  -- hs.json.encode は空テーブルを {} にするが、配列フィールドは [] が必要なため修正
  encoded = encoded:gsub('"windows":%s*{}', '"windows":[]')
  encoded = encoded:gsub('"spaces":%s*{}',  '"spaces":[]')

  local yq = yqBin()
  if yq and path:match("%.yaml$") then
    -- 一時JSONに書き出して yq で YAML 変換
    local tmp = obj.dataDir .. "/.spl_tmp.json"
    local fj = io.open(tmp, "w")
    if not fj then hs.alert.show("SpaceSaver: 一時ファイル書き込み失敗"); return false end
    fj:write(encoded); fj:close()

    -- yq は {screens: ...} JSON を "screens:\n  ..." YAML に変換する
    local yaml, ok2 = hs.execute(
      string.format("%s -p=json -o=yaml %s 2>/dev/null", sq(yq), sq(tmp)))
    os.remove(tmp)

    if not ok2 or not yaml or not yaml:match("%S") then
      hs.alert.show("SpaceSaver: YAML変換失敗"); return false
    end

    -- ヘッダ (modeline / apiVersion / kind) を先頭に付与して保存
    -- yq の出力が "screens:\n ..." で始まるので、そのまま連結すると正しいYAMLになる
    local fw = io.open(path, "w")
    if not fw then hs.alert.show("SpaceSaver: 保存失敗 (" .. path .. ")"); return false end
    fw:write(yamlHeader() .. yaml)
    fw:close()
  else
    -- JSON フォールバック
    local f = io.open(path, "w")
    if not f then hs.alert.show("SpaceSaver: 保存失敗 (" .. path .. ")"); return false end
    f:write(encoded); f:close()
  end
  return true
end

-- ============================================================
-- スクリーン集合 / シグネチャ
-- ============================================================

-- 接続中のスクリーンUUIDを集合（{uuid=true}）で返す
local function currentScreenSet()
  local set = {}
  for _, scr in ipairs(hs.screen.allScreens()) do
    local u = scr:getUUID()
    if u then set[u] = true end
  end
  return set
end

-- 集合からUUIDをソート連結した文字列を返す（変化検知用。ファイルキーには使わない）
local function screenSignature(set)
  local uuids = {}
  for u in pairs(set) do table.insert(uuids, u) end
  table.sort(uuids)
  return table.concat(uuids, "+")
end

-- ============================================================
-- screen メタデータ（ユーザー編集用。リストアには不使用）
-- ============================================================

-- prev（既存 metadata table か nil）をベースに
-- name / frame を実モニタ情報で上書きして返す（他キーは温存）
local function screenMetadata(uuid, prev)
  local meta = {}
  if type(prev) == "table" then
    for k, v in pairs(prev) do meta[k] = v end
  end
  local scr = hs.screen.find(uuid)
  if scr then
    meta.name = scr:name() or uuid
    local f = scr:frame()
    meta.frame = { x = f.x, y = f.y, w = f.w, h = f.h }
  end
  return meta
end

-- ============================================================
-- ウィンドウ記述 / 照合
-- ============================================================

-- ウィンドウから { bundleID, title, frame={x,y,w,h} } を返す（取得失敗時はnil）
local function windowDescriptor(win)
  local ok, r = pcall(function()
    local app = win:application()
    if not app then return nil end
    local bid = app:bundleID()
    if not bid then return nil end
    local f = win:frame()
    return {
      bundleID = bid,
      title    = win:title() or "",
      frame    = { x = f.x, y = f.y, w = f.w, h = f.h },
    }
  end)
  return ok and r or nil
end

-- desc の titlePattern (Luaパターン) または title でキャッシュ済みタイトル文字列を照合する
local function titleMatches(desc, actualTitle)
  if desc.titlePattern then
    return string.find(actualTitle, desc.titlePattern) ~= nil
  end
  return actualTitle == (desc.title or "")
end

-- pool（{ win=ウィンドウ, desc=windowDescriptor } のリスト）から desc に最も近いエントリを取り出す
-- 戻り値: entry, matchKind
--   matchKind = "title"  : bundleID + タイトル一致（優先1）
--   matchKind = "bundle" : 同bundleIDのみ一致（フォールバック）
--   matchKind = nil      : 不一致
local function takeMatchingWindow(desc, pool)
  -- 優先1: bundleID + タイトル一致（パターン優先）
  for i, entry in ipairs(pool) do
    if entry.desc.bundleID == desc.bundleID and titleMatches(desc, entry.desc.title) then
      return table.remove(pool, i), "title"
    end
  end
  -- 優先2: 同bundleIDのフォールバック
  for i, entry in ipairs(pool) do
    if entry.desc.bundleID == desc.bundleID then
      return table.remove(pool, i), "bundle"
    end
  end
  return nil, nil
end

-- desc のタイトル指定 (pattern または title) と bundleID を "[key]=[val] bundleID=[...]" で返す
local function descKeyLabel(desc)
  local key = desc.titlePattern and "pattern" or "title"
  local val = desc.titlePattern or desc.title or ""
  return string.format("%s=[%s] bundleID=[%s]", key, val, desc.bundleID or "")
end

-- ============================================================
-- 無視リスト（トップレベル ignore）
-- ============================================================

-- ignore 規則1件との照合。書かれたフィールドすべてに一致したときだけ真。
-- bundleID だけを書いた規則は、そのアプリの全ウィンドウに一致する。
local function ignoreRuleMatches(rule, bundleID, title)
  if rule.bundleID and rule.bundleID ~= bundleID then return false end
  if rule.titlePattern or rule.title then
    return titleMatches(rule, title or "")
  end
  return rule.bundleID ~= nil
end

-- ignore のいずれかに一致するか
local function isIgnored(rules, bundleID, title)
  for _, rule in ipairs(rules or {}) do
    if ignoreRuleMatches(rule, bundleID, title) then return true end
  end
  return false
end

-- ============================================================
-- 既存レイアウトの再利用（再キャプチャ時のマージ）
-- ============================================================

-- 既存レイアウトの window エントリを、由来（画面 UUID と Space インデックス）つきで集める
local function collectExistingEntries(data)
  local entries = {}
  if not data or type(data.screens) ~= "table" then return entries end
  for uuid, screenData in pairs(data.screens) do
    for spaceIdx, sp in ipairs(screenData.spaces or {}) do
      for _, desc in ipairs(sp.windows or {}) do
        table.insert(entries, { desc = desc, uuid = uuid, spaceIdx = spaceIdx })
      end
    end
  end
  return entries
end

-- 実ウィンドウ actual に一致する既存エントリを取り出す。
-- 復元時と違い bundleID だけのフォールバックは使わない。
-- 使うと titlePattern が無関係なウィンドウに吸い付き、誤った紐づけのまま保存されてしまう。
local function takeExistingEntry(actual, entries)
  for i, e in ipairs(entries) do
    if e.desc.bundleID == actual.bundleID and titleMatches(e.desc, actual.title) then
      return table.remove(entries, i)
    end
  end
  return nil
end

-- spaceID がフルスクリーン型かどうか
local function spaceIsFullscreen(sid)
  local ok, t = pcall(hs.spaces.spaceType, sid)
  return ok and t and t:find("[Ff]ull") ~= nil
end

-- ============================================================
-- ウィンドウプール
-- ============================================================

-- ウィンドウ列挙用の window filter を返す（初回のみ生成）。
-- hs.window.allWindows() は可視 Space のウィンドウしか返さないが、
-- hs.window.filter はウィンドウ生成イベントを購読して非可視 Space の分も保持する。
-- keepActive() で常時追跡させ、Space を巡回せずに全ウィンドウを列挙できるようにする。
local function ensureWindowFilter()
  if not windowFilter then
    windowFilter = hs.window.filter.new(false)
      :setDefaultFilter({})
      :setOverrideFilter({})
    windowFilter:keepActive()
  end
  return windowFilter
end

-- win から { win=..., desc=... } のプールエントリを作る（対象外なら nil）
local function poolEntry(win, ignoreRules)
  -- hs.window.allWindows() に倣い、Finder のデスクトップ (AXScrollArea) のような
  -- ウィンドウでないものを除く。role を読めなかったときは除外しない。
  -- 除外すると、非可視 Space のウィンドウを取りこぼして配置対象から漏らす恐れがある
  local role = nil
  pcall(function() role = win:role() end)
  if role and role ~= "AXWindow" then return nil end

  local isStd = false
  pcall(function() isStd = win:isStandard() end)
  if not isStd then return nil end

  local desc = windowDescriptor(win)
  if not desc then return nil end

  -- 無視対象はプールに載せない。載せると bundleID だけのフォールバック照合で
  -- 別のエントリに割り当てられ、意図しない位置へ動かされる
  if isIgnored(ignoreRules, desc.bundleID, desc.title) then return nil end

  return { win = win, desc = desc }
end

-- Space を切り替えずにウィンドウプールを構築する
local function buildPool(ignoreRules)
  local pool = {}
  for _, win in ipairs(ensureWindowFilter():getWindows()) do
    local entry = poolEntry(win, ignoreRules)
    if entry then table.insert(pool, entry) end
  end
  return pool
end

-- レイアウト中の記述をプールで賄えるか調べ、賄えなかった記述を返す。
-- 配置対象と同じく接続中の画面だけを見る。pool は消費せずコピー上で照合する。
local function unmatchedDescriptors(pool, data)
  local rest = {}
  for i, e in ipairs(pool) do rest[i] = e end

  local missing = {}
  for uuid, screenData in pairs(data.screens) do
    if hs.screen.find(uuid) then
      for _, sp in ipairs(screenData.spaces or {}) do
        for _, desc in ipairs(sp.windows or {}) do
          -- ignore に一致する記述は意図的に配置しないので、取りこぼしとして数えない
          -- （次のキャプチャで削除される）
          if not isIgnored(data.ignore, desc.bundleID, desc.title)
             and not takeMatchingWindow(desc, rest) then
            table.insert(missing, desc)
          end
        end
      end
    end
  end
  return missing
end

-- 未照合の記述のうち、アプリが起動中のものを返す。
-- アプリが起動していないなら単にウィンドウが存在しないだけで、巡回しても見つからない。
local function missingButRunning(missing)
  local result = {}
  for _, desc in ipairs(missing) do
    if desc.bundleID then
      local apps = hs.application.applicationsForBundleID(desc.bundleID)
      if apps and #apps > 0 then table.insert(result, desc) end
    end
  end
  return result
end

-- ============================================================
-- updateMenu の前方宣言（capture 内の finish() から呼ばれる）
-- ============================================================

local updateMenu

-- ============================================================
-- キャプチャ（手動）
-- ============================================================

function obj:capture()
  if busy then
    hs.alert.show("SpaceSaver: キャプチャ中です。しばらくお待ちください")
    return
  end
  busy = true
  hs.alert.show("SpaceSaver: キャプチャ開始…操作しないでください", 999)

  local set = currentScreenSet()

  -- 既存の構成ファイルを探す（あればそのパスに上書き）
  local path, existingData = findConfigFile(set)
  if path then
    print("SpaceSaver: 既存ファイル [" .. basename(path) .. "] を更新")
  else
    path = nextConfigFilePath()
    print("SpaceSaver: 新規ファイル [" .. basename(path) .. "] を作成")
  end

  -- 無視リストと、既存エントリの再利用プールを用意する。
  -- leftover は実ウィンドウと照合するたびに消費され、残ったものは finish() で元の位置に戻す。
  local ignoreRules = existingData and existingData.ignore or nil
  local leftover    = collectExistingEntries(existingData)

  -- 現在のアクティブSpaceを記録（キャプチャ後に戻すため）
  local originalActive = {}
  for uuid in pairs(set) do
    local aok, sid = pcall(hs.spaces.activeSpaceOnScreen, uuid)
    if aok and sid then originalActive[uuid] = sid end
  end

  -- ワークリスト構築（UUID昇順 × Space順で全Space列挙）
  local worklist = {}
  local screenOrder = {}
  for uuid in pairs(set) do table.insert(screenOrder, uuid) end
  table.sort(screenOrder)

  -- newScreens[uuid] = { spaces={}, metadata=... }
  -- spaces は step() で逐次 append、metadata は finish() で設定
  local newScreens = {}
  for _, uuid in ipairs(screenOrder) do
    newScreens[uuid] = { spaces = {} }
    local sok, sids = pcall(hs.spaces.spacesForScreen, uuid)
    if sok and sids then
      for _, sid in ipairs(sids) do
        table.insert(worklist, { uuid = uuid, sid = sid })
      end
    end
  end

  -- キャプチャ完了後の処理
  local function finish()
    hs.alert.closeAll()
    -- 元のアクティブSpaceに戻す
    for uuid, sid in pairs(originalActive) do
      pcall(hs.spaces.gotoSpace, sid)
    end
    later(CAPTURE_SETTLE, function()
      pcall(hs.spaces.closeMissionControl)
      -- screen.metadata を更新（実モニタ情報で上書き、ユーザー追加キーは温存）
      for uuid in pairs(newScreens) do
        local prevMeta = existingData
          and existingData.screens
          and existingData.screens[uuid]
          and existingData.screens[uuid].metadata
        newScreens[uuid].metadata = screenMetadata(uuid, prevMeta)
      end

      -- どのウィンドウにも一致しなかった既存エントリを元の位置に戻す。
      -- アプリを閉じたままキャプチャしても手書き設定が消えないようにするため。
      -- 実在するウィンドウの後ろに置き、復元時の照合で実在分が先に選ばれるようにする。
      -- ignore に一致するものは戻さない。これが不要になったエントリを掃除する手段になる。
      local kept, dropped = 0, 0
      for _, e in ipairs(leftover) do
        local spaces = newScreens[e.uuid] and newScreens[e.uuid].spaces
        if isIgnored(ignoreRules, e.desc.bundleID, e.desc.title) then
          dropped = dropped + 1
        elseif spaces and #spaces > 0 then
          -- 元の Space が無くなっていればその画面の末尾の Space に寄せる
          table.insert(spaces[math.min(e.spaceIdx, #spaces)].windows, e.desc)
          kept = kept + 1
        else
          dropped = dropped + 1
        end
      end
      if kept > 0 or dropped > 0 then
        print(string.format(
          "SpaceSaver: 該当ウィンドウのない既存エントリ 保持=%d 削除=%d", kept, dropped))
      end

      saveConfigFile(path, newScreens, ignoreRules)
      busy = false
      hs.alert.show("SpaceSaver: キャプチャ完了 [" .. basename(path) .. "]")
      if updateMenu then updateMenu() end
    end)
  end

  -- 逐次非同期でSpaceを1つずつキャプチャ
  local function step(i)
    if i > #worklist then finish(); return end
    local item = worklist[i]
    pcall(hs.spaces.gotoSpace, item.sid)
    later(CAPTURE_SETTLE, function()
      local isFS = spaceIsFullscreen(item.sid)
      local windows = {}
      local wok, winIDs = pcall(hs.spaces.windowsForSpace, item.sid)
      if wok and winIDs then
        for _, wid in ipairs(winIDs) do
          local win = hs.window.get(wid)
          if win then
            local isStd = false
            pcall(function() isStd = win:isStandard() end)
            if isStd then
              local desc = windowDescriptor(win)
              if desc and not isIgnored(ignoreRules, desc.bundleID, desc.title) then
                -- 既存エントリに一致するなら、それを再利用して frame だけ実測値に更新する。
                -- 手書きした titlePattern や note を再キャプチャで失わないため。
                local prev = takeExistingEntry(desc, leftover)
                if prev then
                  prev.desc.frame = desc.frame
                  table.insert(windows, prev.desc)
                else
                  table.insert(windows, desc)
                end
              end
            end
          end
        end
      end
      -- 配列の末尾に追加（配列順 = Space順）
      table.insert(newScreens[item.uuid].spaces, {
        type    = isFS and "fullscreen" or "user",
        windows = windows,
      })
      step(i + 1)
    end)
  end

  if #worklist == 0 then finish() else step(1) end
end

-- ============================================================
-- 復元
-- ============================================================

local function restoreCurrentConfig()
  if busy then
    hs.alert.show("SpaceSaver: 処理中です。しばらくお待ちください")
    return
  end

  local set = currentScreenSet()
  local path, data = findConfigFile(set)
  if not path or not data then
    print("SpaceSaver: 現在の構成に対応するファイルなし。スキップ")
    return
  end

  busy = true
  print("SpaceSaver: [" .. basename(path) .. "] を復元開始")
  hs.alert.show("SpaceSaver: [" .. basename(path) .. "] 復元中…操作しないでください", 999)

  -- 巡回後に戻すため、現在のアクティブ Space を記録（capture と同じ）
  local originalActive = {}
  for uuid in pairs(set) do
    local aok, sid = pcall(hs.spaces.activeSpaceOnScreen, uuid)
    if aok and sid then originalActive[uuid] = sid end
  end

  -- 対象画面ごとの計画を作る（現在接続中の画面のみ）
  -- plan = { uuid, spaces(レイアウト配列), target(目標user数) }
  local screenPlans = {}
  for uuid, screenData in pairs(data.screens) do
    if hs.screen.find(uuid) then
      local spaces = screenData.spaces or {}
      local userCount = 0
      for _, sp in ipairs(spaces) do
        if (sp.type or "user") ~= "fullscreen" then userCount = userCount + 1 end
      end
      table.insert(screenPlans, { uuid = uuid, spaces = spaces, target = userCount })
    end
  end

  -- 各画面の user Space 数を目標に合わせる Mission Control 操作キューを構築する。
  -- spacesForScreen は user/fullscreen 両方を返すため、user のみを対象に増減する。
  --   add    : user Space を1つ追加
  --   goto   : 削除前に先頭 user Space へ移動（アクティブSpaceは削除できないため）
  --   remove : 末尾の余剰 user Space を1つ削除
  local ops = {}
  for _, plan in ipairs(screenPlans) do
    local userSpaceIDs = {}
    for _, sid in ipairs(hs.spaces.spacesForScreen(plan.uuid) or {}) do
      if not spaceIsFullscreen(sid) then table.insert(userSpaceIDs, sid) end
    end
    local diff = plan.target - #userSpaceIDs
    if diff > 0 then
      -- 不足分を追加
      for _ = 1, diff do
        table.insert(ops, { kind = "add", uuid = plan.uuid })
      end
    elseif diff < 0 then
      -- 余剰分を末尾から削除（macOS制約で最低1個のuser Spaceは残す）
      local removable = math.max(0, #userSpaceIDs - 1)
      local toRemove = math.min(-diff, removable)
      if toRemove > 0 then
        -- 先頭 user Space をアクティブにしてから末尾を削除する
        table.insert(ops, { kind = "goto", sid = userSpaceIDs[1] })
        for k = 0, toRemove - 1 do
          table.insert(ops, { kind = "remove", sid = userSpaceIDs[#userSpaceIDs - k] })
        end
      end
    end
  end

  -- Space を切り替えた場合だけ元のアクティブ Space に戻し、Mission Control を閉じる。
  -- 切り替えていなければ画面はそのままなので、余計な切替を挟まず即座に終える。
  local spacesTouched = (#ops > 0)

  local function announceDone()
    busy = false
    hs.alert.closeAll()
    hs.alert.show("SpaceSaver: [" .. basename(path) .. "] 復元完了")
    print("SpaceSaver: [" .. basename(path) .. "] 復元完了")
  end

  local function finish()
    if not spacesTouched then
      announceDone()
      return
    end
    for uuid, sid in pairs(originalActive) do
      pcall(hs.spaces.gotoSpace, sid)
    end
    later(CAPTURE_SETTLE, function()
      pcall(hs.spaces.closeMissionControl)
      announceDone()
    end)
  end

  -- 事前に収集したウィンドウプールを使って各画面のウィンドウを配置する。
  -- pool 要素は { win=ウィンドウ, desc=windowDescriptor } のキャッシュ済みエントリ。
  -- ① タスクリストを同期的に構築し、
  -- ② spaceMove.moveWindowToSpace で逐次・非同期に実行する。
  --    既に目的 Space に居るウィンドウはフレーム補正のみで、Space は切り替わらない。
  local function placeWindows(pool)
    -- ① タスクリスト構築（pool.takeMatchingWindow の消費順を現状と同一に保つ）
    local tasks = {}
    -- 並べ替えのため、レイアウト上の何番目の Space に全画面化したかを控える
    local fsPlacements = {}
    for _, plan in ipairs(screenPlans) do
      -- user Space のみを並び順どおりに抽出（fullscreen を除外）。
      -- レイアウトの user Space 配列は、この userSpaceIDs に順番で対応する。
      local userSpaceIDs = {}
      for _, sid in ipairs(hs.spaces.spacesForScreen(plan.uuid) or {}) do
        if not spaceIsFullscreen(sid) then table.insert(userSpaceIDs, sid) end
      end
      local userIdx = 0

      for spIdx, sp in ipairs(plan.spaces) do
        if (sp.type or "user") == "fullscreen" then
          -- フルスクリーンSpace: setFullScreen(true) タスク
          for _, desc in ipairs(sp.windows or {}) do
            local entry, matchKind = takeMatchingWindow(desc, pool)
            if entry then
              table.insert(tasks, {
                kind = "fullscreen",
                win = entry.win, desc = desc,
                actualTitle = entry.desc.title, matchKind = matchKind,
                uuid = plan.uuid, spaceIdx = spIdx,
              })
            else
              print(string.format("未配置 %s actualTitle=[] reason=[該当ウィンドウなし]",
                descKeyLabel(desc)))
            end
          end
        else
          -- user Space: Space 移動タスク
          userIdx = userIdx + 1
          local sid = userSpaceIDs[userIdx]
          if sid then
            for _, desc in ipairs(sp.windows or {}) do
              local entry, matchKind = takeMatchingWindow(desc, pool)
              if entry then
                table.insert(tasks, {
                  kind = "space",
                  win = entry.win, desc = desc,
                  actualTitle = entry.desc.title, matchKind = matchKind,
                  sid = sid, uuid = plan.uuid, userIdx = userIdx,
                })
              else
                print(string.format("未配置 %s actualTitle=[] reason=[該当ウィンドウなし]",
                  descKeyLabel(desc)))
              end
            end
          else
            -- 実 Space 数が YAML の user Space 数より少ない場合
            for _, desc in ipairs(sp.windows or {}) do
              print(string.format("未配置 %s actualTitle=[] reason=[対象Spaceなし (userSpace#%d)]",
                descKeyLabel(desc), userIdx))
            end
          end
        end
      end
    end

    -- 全画面化したウィンドウの Space を、レイアウトが指す位置へ並べ替える。
    -- フルスクリーン Space は必ず末尾に作られるため、作っただけでは順番が合わない。
    local function arrangeFullscreenOrder()
      if not obj.restoreFullscreenSpaceOrder or #fsPlacements == 0 then
        finish(); return
      end

      -- 画面ごとに { sid, index } を集め、index の昇順に並べる
      local byScreen = {}
      for _, p in ipairs(fsPlacements) do
        local spaces = hs.spaces.windowSpaces(p.win) or {}
        local sid = spaces[1]
        if sid and spaceIsFullscreen(sid) then
          byScreen[p.uuid] = byScreen[p.uuid] or {}
          table.insert(byScreen[p.uuid], { sid = sid, index = p.index })
        end
      end

      local work = {}
      for uuid, targets in pairs(byScreen) do
        table.sort(targets, function(a, b) return a.index < b.index end)
        table.insert(work, { uuid = uuid, targets = targets })
      end

      local function step(i)
        if i > #work then finish(); return end
        spaceOrder.arrange(work[i].uuid, work[i].targets, function(moved)
          if moved > 0 then
            spacesTouched = true
            print(string.format("SpaceSaver: screen=[%s] のフルスクリーン Space を %d 件並べ替え",
              work[i].uuid, moved))
          end
          step(i + 1)
        end)
      end
      step(1)
    end

    -- ② タスクを逐次・非同期で実行（ドラッグ方式に落ちる場合があるので1件ずつ待つ）
    local function runTask(i)
      if i > #tasks then arrangeFullscreenOrder(); return end
      local t = tasks[i]
      if t.kind == "fullscreen" then
        spaceMove.makeFullScreen(t.win, t.uuid, t.desc.frame, function(method)
          if method ~= "none" then spacesTouched = true end
          table.insert(fsPlacements, { uuid = t.uuid, index = t.spaceIdx, win = t.win })
          local note = t.matchKind == "bundle" and " (bundleIDのみ一致)" or ""
          print(string.format("配置 %s actualTitle=[%s] -> screen=[%s] fullscreen=[%s]%s",
            descKeyLabel(t.desc), t.actualTitle, t.uuid, method, note))
          runTask(i + 1)
        end)
      elseif t.kind == "space" then
        spaceMove.moveWindowToSpace(t.win, t.sid, t.desc.frame, obj.spaceSwitchHotkeys,
          function(method)
            if method == "drag" or method == "failed" then spacesTouched = true end
            local note = t.matchKind == "bundle" and " (bundleIDのみ一致)" or ""
            print(string.format(
              "配置 %s actualTitle=[%s] -> screen=[%s] userSpace#%d spaceID=[%s] move=[%s]%s",
              descKeyLabel(t.desc), t.actualTitle, t.uuid, t.userIdx,
              tostring(t.sid), method, note))
            runTask(i + 1)
          end)
      else
        runTask(i + 1)
      end
    end

    runTask(1)
  end

  -- 全 Space を巡回してウィンドウプールを取り直す（フォールバック）。
  -- hs.window.filter のキャッシュが不完全だったときだけ通る経路。
  local function rescanSpaces(pool, onDone)
    local worklist = {}
    for _, plan in ipairs(screenPlans) do
      for _, sid in ipairs(hs.spaces.spacesForScreen(plan.uuid) or {}) do
        table.insert(worklist, sid)
      end
    end

    local seen = {}
    for _, e in ipairs(pool) do
      local id = e.win:id()
      if id then seen[id] = true end
    end

    spacesTouched = true
    local function step(i)
      if i > #worklist then onDone(pool); return end
      pcall(hs.spaces.gotoSpace, worklist[i])
      later(CAPTURE_SETTLE, function()
        local wok, winIDs = pcall(hs.spaces.windowsForSpace, worklist[i])
        if wok and winIDs then
          for _, wid in ipairs(winIDs) do
            if not seen[wid] then
              seen[wid] = true
              local win = hs.window.get(wid)
              local entry = win and poolEntry(win, data.ignore)
              if entry then table.insert(pool, entry) end
            end
          end
        end
        step(i + 1)
      end)
    end

    if #worklist == 0 then onDone(pool) else step(1) end
  end

  -- Space を切り替えずにプールを組んで配置する。
  -- アプリが起動中なのに照合できなかった記述は、ウィンドウ列挙の取りこぼしか
  -- レイアウトの記述ずれのどちらかなので、判断材料としてログに出す。
  local function buildPoolAndPlace()
    local pool     = buildPool(data.ignore)
    local unmet    = missingButRunning(unmatchedDescriptors(pool, data))

    if #unmet > 0 then
      print(string.format("SpaceSaver: アプリ起動中だが照合できない記述が %d 件あります", #unmet))
      for _, desc in ipairs(unmet) do
        print("  " .. descKeyLabel(desc))
      end
      if obj.rescanSpacesIfIncomplete then
        print("SpaceSaver: rescanSpacesIfIncomplete により全 Space を巡回して取り直します")
        rescanSpaces(pool, placeWindows)
        return
      end
    end

    placeWindows(pool)
  end

  -- 操作キューを1つずつ非同期で実行（Mission Control の競合を避けるため逐次・遅延つき）
  local function runOps(i)
    if i > #ops then
      pcall(hs.spaces.closeMissionControl)
      later(RESTORE_DELAY, buildPoolAndPlace)
      return
    end
    local op = ops[i]
    if op.kind == "add" then
      pcall(hs.spaces.addSpaceToScreen, op.uuid, false)
      later(MC_STEP_DELAY, function() runOps(i + 1) end)
    elseif op.kind == "goto" then
      pcall(hs.spaces.gotoSpace, op.sid)
      later(MC_STEP_DELAY, function() runOps(i + 1) end)
    elseif op.kind == "remove" then
      pcall(hs.spaces.removeSpace, op.sid, false)
      later(MC_STEP_DELAY, function() runOps(i + 1) end)
    else
      runOps(i + 1)
    end
  end

  if #ops == 0 then
    -- 既に数が合っている場合は調整不要。すぐプール構築→配置する
    buildPoolAndPlace()
  else
    runOps(1)
  end
end

-- ============================================================
-- メニューバー
-- ============================================================

updateMenu = function()
  if not menubar then return end

  local set = currentScreenSet()
  local path, _ = findConfigFile(set)
  local label = path and basename(path) or "(未登録)"

  menubar:setMenu({
    {
      title = "レイアウトをキャプチャ",
      fn = function() obj:capture() end,
    },
    { title = "-" },
    {
      title = "現在の構成: " .. label,
      disabled = true,
    },
    {
      title = "スクリーンUUIDを表示",
      fn = function()
        local uuids = {}
        for u in pairs(set) do table.insert(uuids, u) end
        table.sort(uuids)
        hs.alert.show(table.concat(uuids, "\n"), 8)
      end,
    },
    { title = "-" },
    { title = "再リストア", fn = function() restoreCurrentConfig() end },
    {
      title = "設定ファイルを開く",
      fn = function()
        if path then
          hs.execute("open " .. sq(path))
        else
          hs.alert.show("SpaceSaver: 現在の構成のファイルがありません。まずキャプチャしてください")
        end
      end,
    },
    { title = "-" },
    { title = "デバッグ: dump", fn = function() obj:dump() end },
  })
end

-- ============================================================
-- スクリーン変化ハンドラ
-- ============================================================

local function onScreenChange()
  local newSig = screenSignature(currentScreenSet())
  if newSig ~= trackedSignature then
    trackedSignature = newSig
    restoreCurrentConfig()
  end
  updateMenu()
end

-- ============================================================
-- 公開 API
-- ============================================================

-- hs.loadSpoon() から自動で呼ばれる。
-- watcher/menubar は :start() で構築するためここでは何もしない。
-- dataDir は loadSpoon 後・:start() 前にカスタマイズできる。
function obj:init()
end

-- ホットキーを SpaceSaver の各アクションに割り当てる。
-- mapping は次のキーを持つテーブル（いずれも任意）:
--   capture: レイアウトをキャプチャ（hammerspoon://space-capture と同じ）
--   restore: レイアウトを復元（hammerspoon://space-restore と同じ）
-- 例:
--   spoon.SpaceSaver:bindHotkeys({
--     capture = {{"cmd","alt","ctrl"}, "c"},
--     restore = {{"cmd","alt","ctrl"}, "r"},
--   })
function obj:bindHotkeys(mapping)
  local spec = {
    capture = hs.fnutils.partial(self.capture, self),
    restore = hs.fnutils.partial(restoreCurrentConfig),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end

function obj:start()
  trackedSignature = screenSignature(currentScreenSet())

  -- ここから追跡を始めることで、以後に生成されたウィンドウは
  -- 非可視 Space のものも取りこぼさずプールに載る
  ensureWindowFilter()

  -- メニューバー
  menubar = hs.menubar.new()
  if menubar then
    -- SVGアイコンをテンプレートイメージ（ライト/ダークモード自動対応）として使用
    local icon = hs.image.imageFromPath(hs.spoons.resourcePath("space_layout.svg"))
    if icon then
      icon:setSize({ w = 18, h = 18 })
      menubar:setIcon(icon, true)
    else
      menubar:setTitle("⊞")
    end
    updateMenu()
  end

  -- URLイベント（シェルから open -g "hammerspoon://space-capture" で起動可）
  hs.urlevent.bind("space-capture", function() obj:capture() end)
  hs.urlevent.bind("space-restore", function() restoreCurrentConfig() end)

  -- スクリーンウォッチャー（SCREEN_SETTLE秒のデバウンス付き）
  screenWatcher = hs.screen.watcher.new(function()
    if screenTimer then screenTimer:stop() end
    screenTimer = hs.timer.doAfter(SCREEN_SETTLE, onScreenChange)
  end)
  screenWatcher:start()

  print("SpaceSaver: 起動 (構成ファイル数: " .. #listConfigFiles() .. ")")
  return self
end

function obj:stop()
  if screenWatcher then screenWatcher:stop(); screenWatcher = nil end
  if screenTimer   then screenTimer:stop();   screenTimer   = nil end
  if menubar       then menubar:delete();      menubar       = nil end
  if windowFilter  then windowFilter:delete();          windowFilter = nil end
  hs.urlevent.bind("space-capture", nil)
  hs.urlevent.bind("space-restore", nil)
  print("SpaceSaver: 停止")
  return self
end

-- デバッグ用: 現在の構成に一致するファイルの内容をコンソールに表示
function obj:dump()
  local set = currentScreenSet()
  local path, data = findConfigFile(set)
  if path then
    print("File: " .. path)
    print(hs.inspect(data))
  else
    print("SpaceSaver: 現在の構成に対応するファイルなし")
    local files = listConfigFiles()
    if #files > 0 then
      print("既知のファイル: " .. hs.inspect(files))
    else
      print("構成ファイルが1件もありません")
    end
  end
end

return obj
