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

  既知の制限:
    - Luaパターン照合（完全なPCREではない）
    - フルスクリーンSpaceの並び順は厳密復元不可
    - 余剰Spaceは削除しない（不足分追加のみ）
    - キャプチャ中はMission Controlが各Spaceぶん切り替わる
    - 再キャプチャでscreen.metadata.name/frameは実情報で上書き（ユーザーが追加した他キーは温存）
    - yq不在時はJSONフォールバック（space_layouts_<n>.json）で動作
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

-- ============================================================
-- 設定定数
-- ============================================================

local YQ_DEFAULT = "/opt/homebrew/bin/yq"

local SCREEN_SETTLE  = 2.0   -- 秒: モニター変化後、復元開始までのデバウンス
local RESTORE_DELAY  = 1.5   -- 秒: Space追加/削除後、ウィンドウ移動までの待機
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

-- ============================================================
-- ユーティリティ
-- ============================================================

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
local function saveConfigFile(path, screens)
  -- { screens = {...} } としてエンコード
  local ok, encoded = pcall(hs.json.encode, { screens = screens }, true)
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

-- desc の titlePattern (Luaパターン) または title でウィンドウを照合する
local function titleMatches(desc, win)
  local ok, t = pcall(function() return win:title() or "" end)
  local title = ok and t or ""
  if desc.titlePattern then
    return string.find(title, desc.titlePattern) ~= nil
  end
  return title == (desc.title or "")
end

-- pool（ウィンドウのリスト）から desc に最も近いウィンドウを取り出す
local function takeMatchingWindow(desc, pool)
  -- 優先1: bundleID + タイトル一致（パターン優先）
  for i, win in ipairs(pool) do
    local d = windowDescriptor(win)
    if d and d.bundleID == desc.bundleID and titleMatches(desc, win) then
      return table.remove(pool, i)
    end
  end
  -- 優先2: 同bundleIDのフォールバック
  for i, win in ipairs(pool) do
    local d = windowDescriptor(win)
    if d and d.bundleID == desc.bundleID then
      return table.remove(pool, i)
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
    hs.timer.doAfter(CAPTURE_SETTLE, function()
      pcall(hs.spaces.closeMissionControl)
      -- screen.metadata を更新（実モニタ情報で上書き、ユーザー追加キーは温存）
      for uuid in pairs(newScreens) do
        local prevMeta = existingData
          and existingData.screens
          and existingData.screens[uuid]
          and existingData.screens[uuid].metadata
        newScreens[uuid].metadata = screenMetadata(uuid, prevMeta)
      end
      saveConfigFile(path, newScreens)
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
    hs.timer.doAfter(CAPTURE_SETTLE, function()
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
              if desc then table.insert(windows, desc) end
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
  local set = currentScreenSet()
  local path, data = findConfigFile(set)
  if not path or not data then
    print("SpaceSaver: 現在の構成に対応するファイルなし。スキップ")
    return
  end

  print("SpaceSaver: [" .. basename(path) .. "] を復元")
  hs.alert.show("SpaceSaver: [" .. basename(path) .. "] 復元中…", 3)

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

  -- Space数調整の完了後に、各画面のウィンドウを配置する
  local function placeWindows()
    for _, plan in ipairs(screenPlans) do
      -- user Space のみを並び順どおりに抽出（fullscreen を除外）。
      -- レイアウトの user Space 配列は、この userSpaceIDs に順番で対応する。
      local userSpaceIDs = {}
      for _, sid in ipairs(hs.spaces.spacesForScreen(plan.uuid) or {}) do
        if not spaceIsFullscreen(sid) then table.insert(userSpaceIDs, sid) end
      end
      local pool = hs.window.allWindows()
      local userIdx = 0

      for _, sp in ipairs(plan.spaces) do
        if (sp.type or "user") == "fullscreen" then
          -- フルスクリーンSpace: 対応ウィンドウを setFullScreen(true) で全画面化
          for _, desc in ipairs(sp.windows or {}) do
            local win = takeMatchingWindow(desc, pool)
            if win then pcall(function() win:setFullScreen(true) end) end
          end
        else
          -- user Space: 配列順に spaceID と対応付けてウィンドウを移動・リサイズ
          userIdx = userIdx + 1
          local sid = userSpaceIDs[userIdx]
          if sid then
            for _, desc in ipairs(sp.windows or {}) do
              local win = takeMatchingWindow(desc, pool)
              if win then
                pcall(function()
                  hs.spaces.moveWindowToSpace(win, sid, true)
                  if desc.frame then
                    win:setFrame(hs.geometry.rect(
                      desc.frame.x, desc.frame.y,
                      desc.frame.w, desc.frame.h))
                  end
                end)
              end
            end
          end
        end
      end
    end
  end

  -- 操作キューを1つずつ非同期で実行（Mission Control の競合を避けるため逐次・遅延つき）
  local function runOps(i)
    if i > #ops then
      pcall(hs.spaces.closeMissionControl)
      hs.timer.doAfter(RESTORE_DELAY, placeWindows)
      return
    end
    local op = ops[i]
    if op.kind == "add" then
      pcall(hs.spaces.addSpaceToScreen, op.uuid, false)
    elseif op.kind == "goto" then
      pcall(hs.spaces.gotoSpace, op.sid)
    elseif op.kind == "remove" then
      pcall(hs.spaces.removeSpace, op.sid, false)
    end
    hs.timer.doAfter(MC_STEP_DELAY, function() runOps(i + 1) end)
  end

  if #ops == 0 then
    -- 既に数が合っている場合は調整不要。すぐ配置する
    placeWindows()
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
