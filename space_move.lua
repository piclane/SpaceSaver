--[[
  space_move.lua — SpaceSaver Spoon 内部モジュール
  -------------------------------------------------------
  ウィンドウを別の Space へ移動する。

  hs.spaces.moveWindowToSpace は macOS 15 以降、成功を返しながら実際には
  ウィンドウを移動しない (Hammerspoon issue #3698)。戻り値では判定できないため、
  実行後に hs.spaces.windowSpaces で検算し、無効ならドラッグ方式へ切り替える。
  判定結果はセッション内で保持し、2件目以降は検算を省く。

  ドラッグ方式:
    1. ウィンドウをアプリごと前面に出す（focus）
    2. タイトルバーの候補点を掴み、把持が成立する量まで動かす
    3. 掴んだまま「操作スペースを左/右に移動」ショートカットを送出
    4. mouseUp 後、ウィンドウフレームを正確な位置に補正

  把持点は固定オフセットでは決まらない。左端はリサイズ枠に当たり、水平中央は
  Chrome のタブに当たる。そこで信号ボタン（閉じる・最小化・全画面）の実測位置を
  基準に候補点を組み立てる。ボタンの真上・隙間・左右はタイトルバーの造りが
  アプリごとに違っても掴める見込みが高く、ボタン自体を押す危険もない。

  掴めたかどうかを掴んだ直後に見分ける手段はない。試しに動かしてフレームを読む
  方法は実測で当てにならなかった。ウィンドウが動いてもフレームに出ないアプリが
  あるうえ（Chrome は mouseUp まで反映しないことがある）、試し掴みはタブを掴んで
  動かすなどの副作用を残す。判定はせず、Space 移動後の windowSpaces による
  検算に任せる。失敗したら次の試行では別の候補点から始める。

  ドラッグ量にも下限がある。実測ではどのアプリも 10px 手前では動き出さないため、
  1px のドラッグでは把持が成立しない。余裕を見た量を動かしてから送出する。

  参考: https://gist.github.com/xgungnir/a02f059b29adacaf7df884920e127533

  公開インターフェース:
    M.makeFullScreen(win, screenUUID, frame, done)
      win        : hs.window
      screenUUID : フルスクリーンにする対象モニタの UUID
      frame      : {x,y,w,h} 目的モニタへ寄せるための矩形（nil なら実モニタの矩形）
      done       : 完了コールバック。常に1回だけ、結果を引数に呼ばれる
                   "none"     既に目的モニタでフルスクリーンだった
                   "enter"    同じモニタ上でフルスクリーン化した
                   "rescreen" 別モニタから移して入れ直した

    M.moveWindowToSpace(win, sid, frame, hotkeys, done)
      win     : hs.window
      sid     : 目的 Space ID
      frame   : {x,y,w,h} 最終フレーム（nil 可）
      hotkeys : { left={{mods},key}, right={{mods},key} }（nil ならOS設定から自動検出）
      done    : 完了コールバック。常に1回だけ、結果を引数に呼ばれる
                "none"        既に目的 Space に居たのでフレーム補正のみ
                "native"      hs.spaces.moveWindowToSpace で移動
                "drag"        タイトルバーを掴むドラッグ方式で移動
                "mc"          Mission Control 方式で移動（space_mc.lua）
                "failed"      移動できずフレーム補正のみ
                "unsupported" このアプリでは移動できないと判明済みのため
                              試行せずフレーム補正のみ
--]]

local M = {}

-- Mission Control 方式（space_mc.lua）を読み込む。
-- 自分と同じフォルダから読むので、Spoon の場所に依存しない
local MY_DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local spaceMC = dofile(MY_DIR .. "space_mc.lua")

-- ============================================================
-- タイミング定数（Gist のタイミングを踏襲）
-- ============================================================

-- タイトルバーの把持点は固定できない（grabCandidates で候補を組み立てる）。
-- 左端 (x+5) はリサイズ枠に当たり、掴んだつもりで横に伸縮させるだけになる。
-- 水平中央は Chrome のタブに当たる。Chrome のタブはウィンドウ上端 0px から
-- タブ帯の全高を占めるので、タブの上には掴める余白がない。タブを 1px 動かしても
-- Chrome はタブ操作として扱うため、Space だけが切り替わってウィンドウが取り残される。
-- タブは 4〜5 枚を超えると水平中央まで届くので、中央固定は事実上ほぼ外れる。
local GRAB_EDGE_MIN  = 5    -- 左右端・下端から最低これだけ離す（リサイズ枠の回避）
local GRAB_TOP_MIN   = 3    -- 上端から最低これだけ下げる（同上）
local AX_PARENT_MAX  = 12   -- AXWindow の祖先を辿る深さの上限
-- ウィンドウが動き出すには一定量のドラッグが要る。実測では 10px 手前では
-- どのアプリも動かず、cmd を伴わない 1px のドラッグでは把持が成立しない。
-- 余裕を見て 24px 動かしてからショートカットを送る
local GRAB_DRAG_DX   = 24   -- 把持を成立させるためのドラッグ量（px）
local GRAB_STEP      = 0.03 -- ドラッグ各段の間隔（秒）
local FOCUS_DELAY    = 0.25 -- focus 後、前面化が反映されるまでの待機（秒）
local FOCUS_RETRY    = 2    -- 前面化を確認できないときの再試行回数
local GOTO_DELAY   = 0.5   -- gotoSpace 後、ウィンドウ把持までの待機（秒）
local DOWN_DELAY   = 0.03  -- mouseDown 後（秒）
local DRAG_DELAY   = 0.05  -- 把持確立後、ショートカット送出まで（秒）
local KEY_DELAY    = 0.6   -- 各ショートカット送出後（Space 切替アニメ待ち）（秒）
local KEY_HOLD     = 0.03  -- keyDown から keyUp まで（秒）
local DROP_DELAY   = 0.1   -- mouseUp 後、フレーム復元まで（秒）
local VERIFY_DELAY = 0.2   -- 純正 API 実行後、windowSpaces を検算するまで（秒）
-- 移動の成否は windowSpaces で見るが、この値は操作の直後にはまだ古い。
-- 一度見ただけで判断すると、移動できているのに失敗と誤判定する。
-- 誤判定はログを汚すだけでなく、アプリ単位の失敗数を積み上げて
-- そのアプリの移動を諦めさせてしまうので、真になるまで見に行く
local SETTLE_POLL    = 0.05 -- 所属 Space の反映を見に行く間隔（秒）
local SETTLE_TIMEOUT = 1.5  -- 同上の上限（秒）
local TIMEOUT_BASE = 3.0   -- 安全タイムアウトの固定分（秒）。可変分は Space 移動段数に比例

-- フルスクリーン切替はアニメーションを伴うため、各段で収まるのを待つ
local FS_EXIT_DELAY  = 1.2  -- フルスクリーン解除後（秒）
local FS_FRAME_DELAY = 0.4  -- 目的モニタへ寄せた後（秒）
local FS_ENTER_DELAY = 1.2  -- フルスクリーン化後（秒）

-- ============================================================
-- 修飾キー / ショートカット設定
-- ============================================================

-- CGEventFlags のビットマスク
local FLAG = {
  shift      = 0x020000,
  ctrl       = 0x040000,
  alt        = 0x080000,
  cmd        = 0x100000,
  numericpad = 0x200000,
  fn         = 0x800000,
}

local MOD_ALIAS = {
  ctrl = "ctrl", control = "ctrl",
  alt  = "alt",  option  = "alt",
  cmd  = "cmd",  command = "cmd",
  shift = "shift", fn = "fn",
}

-- macOS「システム設定 > キーボード > キーボードショートカット > Mission Control」の
-- 「操作スペースを左/右に移動」に対応する symbolic hotkey ID
local SYMBOLIC_ID = { left = "79", right = "81" }
local SYMBOLIC_PLIST =
  os.getenv("HOME") .. "/Library/Preferences/com.apple.symbolichotkeys.plist"

-- hs.spaces.moveWindowToSpace が実効性を持つか。
-- nil=未判定 / true=動く / false=動かない。一度だけ実地に試して判定する。
local nativeMoveWorks = nil

-- ドラッグ方式が使えるかはアプリごとに違う。掴める点が見つからないアプリや、
-- 掴めてもウィンドウが Space の切替について来ないアプリがありうる。
-- アプリ単位で連続失敗を数え、規定回数に達したらそのアプリでは以降試さない。
-- 全体で1つのフラグにすると、1つのアプリの失敗で他のアプリまで諦めてしまう。
local dragFailures = {}   -- bundleID -> 連続失敗回数
local dragBlocked  = {}   -- bundleID -> true なら以降ドラッグを試さない
local DRAG_GIVEUP  = 3    -- 同じアプリでも成否が揺れることがあるので少し余裕を持たせる

-- Mission Control 方式も効かなかったアプリ。両方だめなら移動を諦める
local mcFailures = {}     -- bundleID -> 連続失敗回数
local mcBlocked  = {}     -- bundleID -> true なら以降 Mission Control を試さない

-- ドラッグ方式が効かず Mission Control 方式で移せたアプリ。
-- 効かないと分かった時点で切り替える。連続失敗を数えてから切り替えたのでは、
-- そのアプリのウィンドウを移すたびに無駄なドラッグを繰り返すことになる
local mcPreferred = {}    -- bundleID -> true なら最初から Mission Control 方式

-- ドラッグ方式は 1 Space ずつ送るので、離れているほど時間がかかる（1 段あたり
-- KEY_DELAY ぶん）。Mission Control 方式は距離によらず 1.8 秒前後で終わるため、
-- これだけ離れていれば後者のほうが速い
local MC_STEP_THRESHOLD = 3

-- 掴めた点はアプリ内で共通なので、bundleID ごとに覚えて次から最初に試す
local grabPoints = {}     -- bundleID -> { dx = 数値, dy = 数値 }

-- 失敗した回数。次の試行で別の候補から始めるための送り幅に使う
local grabRotation = {}   -- bundleID -> 数値

-- OS 設定から読んだショートカット（セッション内キャッシュ）
local systemHotkeys = nil

-- ============================================================
-- ユーティリティ
-- ============================================================

-- hs.timer.doAfter は戻り値を保持しないとタイマーが GC され、
-- コールバックが呼ばれないまま非同期処理が止まる。発火するまで参照を持つ。
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

local function cancelLater(t)
  if not t then return end
  t:stop()
  pendingTimers[t] = nil
end

-- ipairs テーブルから値のインデックスを返す（なければ nil）
local function indexOf(tbl, val)
  for i, v in ipairs(tbl) do
    if v == val then return i end
  end
  return nil
end

-- win が属する Space ID の配列を返す（取得失敗時は空配列）
local function windowSpacesOf(win)
  local ok, r = pcall(hs.spaces.windowSpaces, win)
  if ok and type(r) == "table" then return r end
  return {}
end

-- cond() が真になるまで待って cb(真になったか) を呼ぶ。
-- 真ならその時点で、駄目なら timeout 秒後に呼ぶ
local function waitUntil(cond, timeout, cb)
  local t0 = hs.timer.secondsSinceEpoch()
  local function step()
    if cond() then cb(true); return end
    if hs.timer.secondsSinceEpoch() - t0 > timeout then cb(false); return end
    later(SETTLE_POLL, step)
  end
  step()
end

-- win が targetSid に入るのを待つ
local function waitForSpace(win, targetSid, cb)
  waitUntil(function() return indexOf(windowSpacesOf(win), targetSid) ~= nil end,
    SETTLE_TIMEOUT, cb)
end

-- frame が指定されていればウィンドウに適用する
local function applyFrame(win, frame)
  if not frame then return end
  pcall(function()
    win:setFrame(hs.geometry.rect(frame.x, frame.y, frame.w, frame.h))
  end)
end

-- win のアプリの bundleID を返す（取れなければ "?"）
local function bundleIDOf(win)
  local ok, bid = pcall(function()
    local app = win:application()
    return app and app:bundleID() or nil
  end)
  return (ok and bid) or "?"
end

-- win が今いるスクリーンの UUID を返す（判定できなければ nil）。
-- フルスクリーンのウィンドウでも所属 Space から辿れる
local function screenUUIDOf(win)
  local spaces = windowSpacesOf(win)
  if spaces[1] then
    local ok, uuid = pcall(hs.spaces.spaceDisplay, spaces[1])
    if ok and uuid then return uuid end
  end
  local ok, scr = pcall(function() return win:screen() end)
  if ok and scr then return scr:getUUID() end
  return nil
end

-- スクリーン UUID の矩形を frame 形式で返す（見つからなければ nil）
local function screenFrameOf(uuid)
  local scr = hs.screen.find(uuid)
  if not scr then return nil end
  local f = scr:frame()
  return { x = f.x, y = f.y, w = f.w, h = f.h }
end

-- ============================================================
-- 把持点の探索
-- ============================================================

-- 押すとウィンドウが閉じたり、ファイルのドラッグが始まってしまう要素。
-- 候補は信号ボタンを避けて組み立てるが、造りの違うアプリのための二重の歯止め
local NON_GRABBABLE_ROLE = {
  AXButton    = true, AXMenuButton = true, AXPopUpButton = true,
  AXRadioButton = true, AXCheckBox = true, AXSlider    = true,
  AXTextField = true, AXTextArea   = true, AXLink      = true,
  AXTab       = true, AXTabGroup   = true, AXIncrementor = true,
  AXImage     = true, -- プロキシアイコン。掴むと書類のドラッグが始まる
}

-- (x, y) の最前面要素が win 自身のものかを、AXWindow の祖先まで辿って ID で確かめる。
-- 矩形の一致で見ると、同じ大きさに広げた別ウィンドウが重なったときに自分だと誤認する。
-- 誤認したまま掴むと、覆っている側のウィンドウが Space を渡っていき、対象は残される。
-- 戻り値: 自分のものか, その点の要素のロール
local function hitOwnedBy(win, x, y)
  -- hs.axuielement は遅延ロードなので、参照自体を pcall の内側に置く
  local ok, owned, role = pcall(function()
    local el = hs.axuielement.systemElementAtPosition(x, y)
    if not el then return false, nil end
    local hitRole = el:attributeValue("AXRole")
    local cur, depth = el, 0
    while cur and depth <= AX_PARENT_MAX do
      if cur:attributeValue("AXRole") == "AXWindow" then
        local w = cur:asHSWindow()
        return (w ~= nil and w:id() == win:id()), hitRole
      end
      cur   = cur:attributeValue("AXParent")
      depth = depth + 1
    end
    return false, hitRole
  end)
  if not ok then return false, nil end
  return owned, role
end

-- 信号ボタン（閉じる・最小化・全画面）の矩形をウィンドウ相対で返す。
-- AXWindow の標準属性なので、タイトルバーを自前で描くアプリでも取れる
local function trafficLights(win)
  local out = {}
  pcall(function()
    local axw = hs.axuielement.windowElement(win)
    if not axw then return end
    local f = win:frame()
    for key, attr in pairs({ close = "AXCloseButton",
                             mini  = "AXMinimizeButton",
                             zoom  = "AXZoomButton" }) do
      local el  = axw:attributeValue(attr)
      local pos = el and el:attributeValue("AXPosition")
      local sz  = el and el:attributeValue("AXSize")
      if type(pos) == "table" and type(sz) == "table" then
        out[key] = { x = pos.x - f.x, y = pos.y - f.y, w = sz.w, h = sz.h }
      end
    end
  end)
  return out
end

-- 掴める見込みの高い順に候補点（ウィンドウ相対のオフセット）を並べて返す。
-- 信号ボタンの位置を基準にすると、タイトルバーの高さや造りがアプリごとに違っても
-- ボタンを外した位置を選べる。いずれもタブ帯が始まるより左なので、
-- Chrome のようにタブが上端いっぱいを占めるアプリでもタブを掴まずに済む。
local function grabCandidates(win)
  local f = win:frame()
  local list, seen = {}, {}
  local function add(dx, dy)
    dx, dy = math.floor(dx), math.floor(dy)
    local key = dx .. "," .. dy
    if not seen[key]
       and dx >= GRAB_EDGE_MIN and dx <= f.w - GRAB_EDGE_MIN
       and dy >= GRAB_TOP_MIN  and dy <= f.h - GRAB_EDGE_MIN then
      seen[key] = true
      list[#list + 1] = { dx = dx, dy = dy }
    end
  end

  -- 同じアプリで前回掴めた点を最優先で試す
  local cached = grabPoints[bundleIDOf(win)]
  if cached then add(cached.dx, cached.dy) end

  local b = trafficLights(win)
  if b.close then
    local rightmost = b.zoom or b.mini or b.close
    local rightX    = rightmost.x + rightmost.w
    local aboveY    = math.max(GRAB_TOP_MIN, math.floor(b.close.y / 2))
    local midY      = b.close.y + b.close.h / 2
    local belowY    = b.close.y + b.close.h + 3

    -- ボタンの真上。ボタン自体とウィンドウ上端の間で、たいていウィンドウ本体
    add(b.close.x + b.close.w / 2, aboveY)
    if b.mini then add(b.mini.x + b.mini.w / 2, aboveY) end
    if b.zoom then add(b.zoom.x + b.zoom.w / 2, aboveY) end
    -- ボタンとボタンの隙間
    if b.mini then add((b.close.x + b.close.w + b.mini.x) / 2, midY) end
    if b.mini and b.zoom then add((b.mini.x + b.mini.w + b.zoom.x) / 2, midY) end
    -- ボタン群の右。タブ帯やツールバーが始まるより手前
    add(rightX + 8,  midY)
    add(rightX + 8,  aboveY)
    add(rightX + 20, midY)
    -- ボタン群の左と下
    add(b.close.x / 2, midY)
    add(b.close.x + b.close.w / 2, belowY)
  else
    -- 信号ボタンを取れないウィンドウ向けの保険。
    -- 信号ボタンが取れているときは使わない。ボタン群より右はタブ帯に入りうるので、
    -- 掴み損ねるだけでなくタブを掴んで動かしてしまう
    for _, dy in ipairs({ 6, 12, 20 }) do
      add(60, dy); add(40, dy); add(100, dy)
    end
    add(f.w / 2, 6)
    add(f.w * 0.75, 6)
  end

  return list
end

-- ============================================================
-- 前面化
-- ============================================================

-- ウィンドウをアプリごと前面に出してから cb を呼ぶ。
-- win:raise() はアプリをまたぐ重なり順を変えないため、別アプリのウィンドウに
-- 覆われたままになる。覆われた状態で掴むと、当たり判定も実際のクリックも
-- 覆っている側に吸われる。focus() はアプリを activate するので前面に出る。
local function bringToFront(win, attempt, cb)
  pcall(function() win:focus() end)
  later(FOCUS_DELAY, function()
    local ok, front = pcall(hs.window.frontmostWindow)
    if ok and front and front:id() == win:id() then cb(); return end
    if attempt < FOCUS_RETRY then
      bringToFront(win, attempt + 1, cb)
    else
      -- 前面化を確認できなくても、候補ごとの所有チェックが誤爆を防ぐ
      cb()
    end
  end)
end

-- ============================================================
-- ショートカットの解決と送出
-- ============================================================

-- bindHotkeys 形式 {{mods},key} を { keyCode, flags } に変換する（失敗時 nil）
local function normalizeHotkey(spec)
  if type(spec) ~= "table" then return nil end
  if spec.keyCode then return spec end

  local mods, key = spec[1], spec[2]
  local keyCode = type(key) == "number" and key or hs.keycodes.map[key]
  if type(keyCode) ~= "number" then return nil end

  local flags = 0
  if type(mods) == "table" then
    for _, m in ipairs(mods) do
      local canon = MOD_ALIAS[tostring(m):lower()]
      if canon then flags = flags | FLAG[canon] end
    end
  end

  -- テンキーは NX_NUMERICPADMASK が無いと macOS 側のショートカットが反応しない
  local name = hs.keycodes.map[keyCode]
  if type(name) == "string" and name:match("^pad") then
    flags = flags | FLAG.numericpad
  end

  return { keyCode = keyCode, flags = flags }
end

-- macOS のショートカット設定から左右移動のキーを読む
local function readSystemHotkeys()
  if systemHotkeys then return systemHotkeys end

  local result = {}
  local ok, data = pcall(hs.plist.read, SYMBOLIC_PLIST)
  local dict = ok and type(data) == "table" and data.AppleSymbolicHotKeys
  if type(dict) == "table" then
    for dir, id in pairs(SYMBOLIC_ID) do
      local entry  = dict[id]
      local params = entry and entry.value and entry.value.parameters
      local on     = entry and (entry.enabled == true or entry.enabled == 1)
      if on and type(params) == "table"
         and type(params[2]) == "number" and type(params[3]) == "number" then
        result[dir] = {
          keyCode = math.floor(params[2]),
          flags   = math.floor(params[3]),
        }
      end
    end
  end

  systemHotkeys = result
  return result
end

-- ユーザー設定を優先し、無ければ OS 設定から補う
local function resolveHotkeys(userSpec)
  local sys = readSystemHotkeys()
  return {
    left  = normalizeHotkey(userSpec and userSpec.left)  or sys.left,
    right = normalizeHotkey(userSpec and userSpec.right) or sys.right,
  }
end

-- rawFlags 付きでキーイベントを送出する
-- hs.eventtap.keyStroke は数値パッドフラグを立てないためテンキー割当だと効かない
local function postHotkey(hk)
  local key = hs.keycodes.map[hk.keyCode] or hk.keyCode
  hs.eventtap.event.newKeyEvent({}, key, true):rawFlags(hk.flags):post()
  hs.timer.usleep(math.floor(KEY_HOLD * 1000000))
  hs.eventtap.event.newKeyEvent({}, key, false):rawFlags(hk.flags):post()
end

-- ============================================================
-- ドラッグ方式 Space 移動
-- ============================================================

-- ドラッグ失敗をアプリ単位で記録する。連続で規定回数に達したらそのアプリを諦める
local function noteDragFailure(win, reason)
  local bid = bundleIDOf(win)
  dragFailures[bid] = (dragFailures[bid] or 0) + 1
  print(string.format("SpaceSaver(space_move): %s をドラッグで移動できません（%s）[%d/%d]",
    bid, reason, dragFailures[bid], DRAG_GIVEUP))
  if dragFailures[bid] >= DRAG_GIVEUP and not dragBlocked[bid] then
    dragBlocked[bid] = true
    print(string.format("SpaceSaver(space_move): %s は Space をまたぐ移動に対応できないと判断しました。"
      .. "以降このアプリではフレーム補正のみ行います", bid))
  end
end

-- win を targetSid の Space へドラッグ方式で移動する。
-- 完了時（成功・失敗・タイムアウト問わず）に done() を必ず1回だけ呼ぶ。
local function dragWindowToSpace(win, targetSid, frame, hotkeys, done)
  local called       = false
  local timeoutTimer = nil
  local mouseIsDown  = false

  -- 完了クロージャ（多重呼び出し防止）
  local function finish(method)
    if called then return end
    called = true
    cancelLater(timeoutTimer); timeoutTimer = nil
    -- 中断時にマウスボタンを押したままにしない
    if mouseIsDown then
      pcall(function()
        hs.eventtap.event.newMouseEvent(
          hs.eventtap.event.types.leftMouseUp, hs.mouse.absolutePosition()):post()
      end)
      mouseIsDown = false
    end
    -- Space を移せなかった場合でも、せめて位置とサイズは合わせる
    if method == "failed" then applyFrame(win, frame) end
    done(method)
  end

  local hk = resolveHotkeys(hotkeys)

  -- ============================================================
  -- 目的スクリーン・インデックス・現在 Space を特定
  -- ============================================================

  local screenUUID = hs.spaces.spaceDisplay(targetSid)
  if not screenUUID then
    print("SpaceSaver(space_move): spaceDisplay 失敗 sid=" .. tostring(targetSid))
    finish("failed"); return
  end

  local allSpaces = hs.spaces.spacesForScreen(screenUUID) or {}
  local targetIdx = indexOf(allSpaces, targetSid)
  if not targetIdx then
    print("SpaceSaver(space_move): targetSid が spacesForScreen に見つからない")
    finish("failed"); return
  end

  -- ドラッグ本体（curIdx / targetIdx 確定後）
  local function performDrag(curSid, curIdx)
    local dir = targetIdx > curIdx and "right" or "left"

    -- 既に目的の Space が表示されているなら掴む必要はない。別スクリーンから
    -- 寄せたときに、その画面の表示中 Space がそのまま目的地だった場合がこれに
    -- あたる（Space が1つしかない画面では必ずこうなる）。ここで掴むと、
    -- 動かす必要のないウィンドウを掴んで揺らすだけになる
    if curSid == targetSid then
      applyFrame(win, frame)
      -- setFrame で別スクリーンへ寄せた直後は windowSpaces がまだ古い Space を返す。
      -- 入るまで待たないと、寄せられているのに失敗と誤判定する
      waitForSpace(win, targetSid, function(ok)
        if ok then finish("none"); return end
        noteDragFailure(win, "寄せても目的の Space に入らない")
        finish("failed")
      end)
      return
    end

    if not hk[dir] then
      print(string.format(
        "SpaceSaver(space_move): 「操作スペースを%sに移動」のショートカットが未設定のため移動できない",
        dir == "right" and "右" or "左"))
      finish("failed"); return
    end

    -- フェイルセーフ: 想定所要時間を超えたら強制完了（復元全体が止まらないよう）
    timeoutTimer = later(
      TIMEOUT_BASE + GOTO_DELAY + SETTLE_TIMEOUT
        + (#allSpaces + 1) * (KEY_DELAY + KEY_HOLD),
      function()
        noteDragFailure(win, "タイムアウト")
        finish("failed")
      end)

    -- 掴んだまま Space を渡り、放してフレームを補正する。
    -- 何回送れば届くかは前もって決められない。ドラッグ中のウィンドウが
    -- フルスクリーンの Space をどう扱うかは構成によって変わり、飛ばして先へ進むことも、
    -- そこで置き去りになることもある。そこで1回送るたびに所属を見て、届いたら止める。
    local function crossSpaces(gdx, gdy)
      local maxPress = #allSpaces + 1
      local lastSid  = windowSpacesOf(win)[1]
      local stalled  = 0

      local function release(reason)
        hs.eventtap.event.newMouseEvent(
          hs.eventtap.event.types.leftMouseUp,
          hs.mouse.absolutePosition()):post()
        mouseIsDown = false

        later(DROP_DELAY, function()
          applyFrame(win, frame)
          local bid = bundleIDOf(win)
          -- 放した直後は windowSpaces がまだ追いついていないことがある
          waitForSpace(win, targetSid, function(arrived)
            if arrived then
              -- 効いた点を覚えて、次のウィンドウではここから試す
              grabPoints[bid]   = { dx = gdx, dy = gdy }
              grabRotation[bid] = 0
              dragFailures[bid] = 0
              finish("drag")
              return
            end
            -- この点では掴めていなかった可能性がある。次の試行では別の点から始める
            grabRotation[bid] = (grabRotation[bid] or 0) + 1
            if grabPoints[bid] and grabPoints[bid].dx == gdx
               and grabPoints[bid].dy == gdy then
              grabPoints[bid] = nil
            end
            noteDragFailure(win, string.format("%s, 把持点=+%d,+%d", reason, gdx, gdy))
            finish("failed")
          end)
        end)
      end

      local function press(n)
        if indexOf(windowSpacesOf(win), targetSid) then release(); return end
        -- 2回続けて所属が変わらないなら、掴めていてもウィンドウが付いてこない。
        -- 送り続けても表示だけが流れていくので、そこで打ち切る
        if stalled >= 2 then release("Space の切替について来ない"); return end
        if n > maxPress then release("送出の上限に達しても届かない"); return end

        -- 向きは毎回決め直す。飛ばされて行き過ぎたときに戻れるようにするため
        local nowIdx = indexOf(allSpaces, windowSpacesOf(win)[1]) or curIdx
        local dirNow = targetIdx > nowIdx and "right" or "left"
        if not hk[dirNow] then release("ショートカットが未設定"); return end

        postHotkey(hk[dirNow])
        later(KEY_DELAY, function()
          local now = windowSpacesOf(win)[1]
          if now == lastSid then
            stalled = stalled + 1
          else
            stalled, lastSid = 0, now
          end
          press(n + 1)
        end)
      end

      press(1)
    end

    -- マウスボタンを押したまま anchor から dx だけ動かして把持を成立させる。
    -- 1 発だと動き出さないアプリがあるので段階的に送る
    local function dragBy(anchor, dx)
      local prev = 0
      for _, offset in ipairs({ 2, math.floor(dx / 3), math.floor(dx * 2 / 3), dx }) do
        if offset > prev then
          hs.eventtap.event.newMouseEvent(
            hs.eventtap.event.types.leftMouseDragged,
            hs.geometry.point(anchor.x + offset, anchor.y))
            :setProperty(hs.eventtap.event.properties.mouseEventDeltaX, offset - prev)
            :post()
          hs.timer.usleep(math.floor(GRAB_STEP * 1000000))
          prev = offset
        end
      end
    end

    -- 掴む点を1つ選ぶ。
    -- 掴めたかを掴んだ直後に見分ける手段はない。試しに動かしてフレームを読む方法は
    -- 実測で当てにならなかった。ウィンドウが動いてもフレームに出ないアプリがあり
    -- （Chrome は mouseUp まで反映しないことがある）、掴めているのに掴めなかったと
    -- 誤判定してしまう。しかも試し掴みはタブを掴んで動かすなど副作用が残る。
    -- そこで判定は行わず、Space 移動後の windowSpaces による検算に任せる。
    -- 失敗したら grabRotation を進めて、次の試行では別の点から始める
    local function pickGrabPoint()
      local f = win:frame()
      local valid = {}
      for _, c in ipairs(grabCandidates(win)) do
        local owned, role = hitOwnedBy(win, f.x + c.dx, f.y + c.dy)
        if owned and not (role and NON_GRABBABLE_ROLE[role]) then
          valid[#valid + 1] = c
        end
      end
      if #valid == 0 then return nil end
      local rot = grabRotation[bundleIDOf(win)] or 0
      return valid[(rot % #valid) + 1]
    end

    -- 現在 Space に移動し、ウィンドウを本当に前面へ出してから掴む。
    -- 候補は前面化のあとで選ぶ（位置と信号ボタンの配置が確定してから読む）
    pcall(hs.spaces.gotoSpace, curSid)
    later(GOTO_DELAY, function()
      bringToFront(win, 1, function()
        local c = pickGrabPoint()
        if not c then
          noteDragFailure(win, "掴める点が見つからない")
          finish("failed"); return
        end

        local f  = win:frame()
        local pt = hs.geometry.point(f.x + c.dx, f.y + c.dy)
        hs.mouse.absolutePosition(pt)
        hs.eventtap.event.newMouseEvent(
          hs.eventtap.event.types.leftMouseDown, pt):post()
        mouseIsDown = true

        later(DOWN_DELAY, function()
          dragBy(pt, GRAB_DRAG_DX)
          later(DRAG_DELAY, function() crossSpaces(c.dx, c.dy) end)
        end)
      end)
    end)
  end

  -- ウィンドウが現在いる Space を、目的スクリーンの allSpaces から探す
  local curSid = nil
  for _, s in ipairs(windowSpacesOf(win)) do
    if indexOf(allSpaces, s) then curSid = s; break end
  end

  if curSid then
    -- 同一スクリーン上にある（通常ケース）
    performDrag(curSid, indexOf(allSpaces, curSid))
  else
    -- 別スクリーン上にある（cross-screen）:
    -- setFrame で目的スクリーンへ寄せ、activeSpaceOnScreen で現在 Space を取得
    applyFrame(win, frame)
    later(0.1, function()
      local ok, cs = pcall(hs.spaces.activeSpaceOnScreen, screenUUID)
      local ci = ok and cs and indexOf(allSpaces, cs)
      if not ci then
        print("SpaceSaver(space_move): cross-screen 現在 Space 特定失敗")
        finish("failed"); return
      end
      performDrag(cs, ci)
    end)
  end
end

-- ============================================================
-- 公開 API
-- ============================================================

--- win を screenUUID のモニタでフルスクリーンにする。
--- setFullScreen(true) は「ウィンドウが今いるモニタ」で全画面化するため、
--- 目的のモニタに居ないときは一度解除して寄せ直す必要がある。
--- done(method) は常に1回だけ呼ばれる。
---   "none"     既に目的モニタでフルスクリーンだったので何もしない
---   "enter"    同じモニタ上でフルスクリーン化した
---   "rescreen" 別モニタのフルスクリーンを解除し、目的モニタで入れ直した
function M.makeFullScreen(win, screenUUID, frame, done)
  local isFS = false
  pcall(function() isFS = win:isFullScreen() end)
  local onTarget = (screenUUIDOf(win) == screenUUID)

  -- 目的モニタで既にフルスクリーンなら触らない。
  -- フルスクリーン切替は Space の切替とアニメーションを伴うため、不要なら避ける
  if isFS and onTarget then
    later(0, function() done("none") end)
    return
  end

  local function enter(method)
    pcall(function() win:setFullScreen(true) end)
    later(FS_ENTER_DELAY, function() done(method) end)
  end

  if onTarget then
    enter("enter")
    return
  end

  -- 目的モニタへ寄せてから全画面化する。
  -- レイアウトの frame が無い場合はモニタの矩形で代用する
  local function relocateAndEnter()
    applyFrame(win, frame or screenFrameOf(screenUUID))
    later(FS_FRAME_DELAY, function() enter(isFS and "rescreen" or "enter") end)
  end

  if isFS then
    -- フルスクリーン中は setFrame でモニタを移せないので、いったん解除する
    pcall(function() win:setFullScreen(false) end)
    later(FS_EXIT_DELAY, relocateAndEnter)
  else
    relocateAndEnter()
  end
end

-- 目的 Space まで何段離れているか（同じモニタに居ないときは nil）。
-- ドラッグ方式と Mission Control 方式の使い分けに使う
local function spaceDistance(win, targetSid)
  local uuid = hs.spaces.spaceDisplay(targetSid)
  if not uuid then return nil end
  local all = hs.spaces.spacesForScreen(uuid) or {}
  local ti  = indexOf(all, targetSid)
  if not ti then return nil end
  for _, s in ipairs(windowSpacesOf(win)) do
    local ci = indexOf(all, s)
    if ci then return math.abs(ti - ci) end
  end
  return nil
end

-- Mission Control 方式で移す。成否をログに残し、失敗はアプリ単位で数える
local function missionControlMove(win, targetSid, frame, done)
  local bid = bundleIDOf(win)
  spaceMC.moveWindowToSpace(win, targetSid, function(ok)
    applyFrame(win, frame)
    if ok then
      mcFailures[bid] = 0
      done("mc")
      return
    end
    mcFailures[bid] = (mcFailures[bid] or 0) + 1
    print(string.format(
      "SpaceSaver(space_move): %s を Mission Control でも移動できません [%d/%d]",
      bid, mcFailures[bid], DRAG_GIVEUP))
    if mcFailures[bid] >= DRAG_GIVEUP then
      mcBlocked[bid] = true
      print(string.format("SpaceSaver(space_move): %s は Space をまたぐ移動に対応できないと"
        .. "判断しました。以降このアプリではフレーム補正のみ行います", bid))
    end
    done("failed")
  end)
end

--- win を targetSid の Space へ移動し、frame を適用する。
--- done(method) は常に1回だけ呼ばれる。
function M.moveWindowToSpace(win, targetSid, frame, hotkeys, done)
  -- 既に目的 Space に居るならフレーム補正のみ。Space は切り替えない
  if indexOf(windowSpacesOf(win), targetSid) then
    applyFrame(win, frame)
    -- doAfter(0) で再帰スタック増大を防ぎつつ次タスクへ
    later(0, function() done("none") end)
    return
  end

  local bid = bundleIDOf(win)

  -- どの手段も無効と判明している場合、Space を切り替えずフレームだけ合わせる
  if nativeMoveWorks == false and dragBlocked[bid] and mcBlocked[bid] then
    applyFrame(win, frame)
    later(0, function() done("unsupported") end)
    return
  end

  -- ドラッグ方式と Mission Control 方式の使い分け。
  -- ドラッグ方式は 1 Space ずつ送るので離れているほど時間がかかるが、
  -- Mission Control 方式は距離によらず一定（実測 1.8 秒前後）。
  -- 遠い場合と、ドラッグ方式が効かないと分かっているアプリは後者にする
  local function chooseAndMove()
    local far = (spaceDistance(win, targetSid) or 0) >= MC_STEP_THRESHOLD
    if mcBlocked[bid] then
      dragWindowToSpace(win, targetSid, frame, hotkeys, done)
      return
    end
    if dragBlocked[bid] or mcPreferred[bid] or far then
      missionControlMove(win, targetSid, frame, done)
      return
    end
    dragWindowToSpace(win, targetSid, frame, hotkeys, function(method)
      -- 掴めていてもウィンドウが Space の切替について来ないアプリがある。
      -- その場で Mission Control 方式に切り替えて、この復元のうちに片付ける
      if method ~= "failed" then done(method); return end
      missionControlMove(win, targetSid, frame, function(m)
        if m == "mc" and not mcPreferred[bid] then
          mcPreferred[bid] = true
          print(string.format("SpaceSaver(space_move): %s はドラッグ方式では移動できないため、"
            .. "以降このアプリでは Mission Control 方式を使います", bid))
        end
        done(m)
      end)
    end)
  end

  if nativeMoveWorks == false then
    chooseAndMove()
    return
  end

  -- 純正 API は macOS 15 以降 true を返しつつ移動しないため、戻り値ではなく実効を見る
  pcall(hs.spaces.moveWindowToSpace, win, targetSid)
  later(VERIFY_DELAY, function()
    if indexOf(windowSpacesOf(win), targetSid) then
      nativeMoveWorks = true
      applyFrame(win, frame)
      done("native")
    else
      if nativeMoveWorks == nil then
        nativeMoveWorks = false
        print("SpaceSaver(space_move): hs.spaces.moveWindowToSpace が無効。ドラッグ方式に切り替え")
      end
      chooseAndMove()
    end
  end)
end

return M
