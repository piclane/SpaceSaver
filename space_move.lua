--[[
  space_move.lua — SpaceSaver Spoon 内部モジュール
  -------------------------------------------------------
  ウィンドウを別の Space へ移動する。

  hs.spaces.moveWindowToSpace は macOS 15 以降、成功を返しながら実際には
  ウィンドウを移動しない (Hammerspoon issue #3698)。戻り値では判定できないため、
  実行後に hs.spaces.windowSpaces で検算し、無効ならドラッグ方式へ切り替える。
  判定結果はセッション内で保持し、2件目以降は検算を省く。

  ドラッグ方式:
    1. ウィンドウのタイトルバーをマウスでつかむ（leftMouseDown + 1px drag）
    2. ドラッグ保持中に「操作スペースを左/右に移動」ショートカットを送出
    3. mouseUp 後、ウィンドウフレームを正確な位置に補正

  把持点は固定オフセットでは決まらない。左端はリサイズ枠に当たり、水平中央は
  Chrome のタブに当たる。どちらもウィンドウ本体をつかめない。そこで候補点を
  アクセシビリティの当たり判定にかけ、ウィンドウ本体が返る点を選ぶ。
  それでも移動できないアプリに備え、アプリ単位で連続失敗を数え、
  規定回数に達したら以降そのアプリでは試さずフレーム補正だけ行う。

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
                "drag"        ドラッグ方式で移動
                "failed"      移動できずフレーム補正のみ
                "unsupported" このアプリでは移動できないと判明済みのため
                              試行せずフレーム補正のみ
--]]

local M = {}

-- ============================================================
-- タイミング定数（Gist のタイミングを踏襲）
-- ============================================================

-- タイトルバーの把持点は固定できない（findGrabPoint で探索する）。
-- 左端 (x+5) はリサイズ枠に当たり、掴んだつもりで横に伸縮させるだけになる。
-- 水平中央は Chrome のタブに当たる。Chrome のタブはウィンドウ上端 0px から
-- タブ帯の全高を占めるので、タブの上には掴める余白がない。タブを 1px 動かしても
-- Chrome はタブ操作として扱うため、Space だけが切り替わってウィンドウが取り残される。
-- タブは 4〜5 枚を超えると水平中央まで届くので、中央固定は事実上ほぼ外れる。
local GRAB_DY_LIST     = { 6, 10, 4, 14 } -- 把持点の y オフセット候補（浅い順に試す）
local GRAB_EDGE_MIN    = 12  -- 左右端から最低これだけ離す（リサイズ枠と四隅の回避）
local GRAB_HIT_TOL     = 8   -- AX 要素の矩形がウィンドウ矩形と一致すると見なす差（pt）
local GRAB_DY_FALLBACK = 4   -- 候補が全滅したときに使う従来の y オフセット
local RAISE_DELAY      = 0.05 -- raise 後、重なり順が落ち着くまでの待機（秒）
local GOTO_DELAY   = 0.5   -- gotoSpace 後、ウィンドウ把持までの待機（秒）
local DOWN_DELAY   = 0.03  -- mouseDown 後（秒）
local DRAG_DELAY   = 0.05  -- 1px ドラッグ確立後（秒）
local KEY_DELAY    = 0.6   -- 各ショートカット送出後（Space 切替アニメ待ち）（秒）
local KEY_HOLD     = 0.03  -- keyDown から keyUp まで（秒）
local DROP_DELAY   = 0.1   -- mouseUp 後、フレーム復元まで（秒）
local VERIFY_DELAY = 0.2   -- 純正 API 実行後、windowSpaces を検算するまで（秒）
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

-- (x, y) でウィンドウ本体をつかめるかを AX の当たり判定で調べる。
-- 判定はその点の最前面要素の矩形が f と一致するか。タブ・ボタン・ツールバー・
-- タイトル文字列はいずれも自分自身の小さい矩形を返すので弾ける。
-- 矩形が一致することは、その点を覆う別ウィンドウが無いことの確認にもなる。
local function isGrabbable(x, y, f)
  -- hs.axuielement は遅延ロードなので、参照自体を pcall の内側に置く
  local ok, pos, size = pcall(function()
    local el = hs.axuielement.systemElementAtPosition(x, y)
    if not el then return nil, nil end
    return el:attributeValue("AXPosition"), el:attributeValue("AXSize")
  end)
  if not ok or type(pos) ~= "table" or type(size) ~= "table" then return false end
  return math.abs(pos.x - f.x) <= GRAB_HIT_TOL
     and math.abs(pos.y - f.y) <= GRAB_HIT_TOL
     and math.abs(size.w - f.w) <= GRAB_HIT_TOL
     and math.abs(size.h - f.h) <= GRAB_HIT_TOL
end

-- win の上端付近で、ウィンドウ本体をつかめる点を探して返す（見つからなければ nil）。
-- 探索対象の y は上端寄りに限る。深い位置はコンテンツ領域に入り、そこも
-- ウィンドウと同じ矩形を返すアプリがあるため、掴めると誤判定してしまう。
-- x は Chrome を通すために小さい値から試す。Chrome で空くのは信号ボタンの
-- 上、タブ帯の左内側（左端から 86px ほど）だけで、そこから右は全てタブになる。
local function findGrabPoint(win)
  local f = win:frame()

  local xs, seen = {}, {}
  local function addX(v)
    v = math.floor(v)
    if v >= GRAB_EDGE_MIN and v <= f.w - GRAB_EDGE_MIN and not seen[v] then
      seen[v] = true
      xs[#xs + 1] = v
    end
  end
  addX(60); addX(40)
  addX(f.w / 2); addX(f.w * 0.75); addX(f.w * 0.25); addX(f.w - 60)
  addX(100); addX(20)

  for _, dy in ipairs(GRAB_DY_LIST) do
    for _, dx in ipairs(xs) do
      if isGrabbable(f.x + dx, f.y + dy, f) then
        return hs.geometry.point(f.x + dx, f.y + dy), dx, dy
      end
    end
  end
  return nil
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
    local steps = math.abs(targetIdx - curIdx)
    local dir   = targetIdx > curIdx and "right" or "left"
    if not hk[dir] then
      print(string.format(
        "SpaceSaver(space_move): 「操作スペースを%sに移動」のショートカットが未設定のため移動できない",
        dir == "right" and "右" or "左"))
      finish("failed"); return
    end

    -- フェイルセーフ: 想定所要時間を超えたら強制完了（復元全体が止まらないよう）
    timeoutTimer = later(
      TIMEOUT_BASE + GOTO_DELAY + steps * (KEY_DELAY + KEY_HOLD),
      function()
        noteDragFailure(win, "タイムアウト")
        finish("failed")
      end)

    -- 現在 Space に移動してウィンドウを最前面化
    pcall(hs.spaces.gotoSpace, curSid)
    later(GOTO_DELAY, function()
      pcall(function() win:raise() end)
      -- raise の反映を待つ。重なり順が古いままだと当たり判定が別ウィンドウを拾う
      hs.timer.usleep(math.floor(RAISE_DELAY * 1000000))

      -- タイトルバーの掴める点を探してつかむ（mouseDown + 1px drag）
      local f = win:frame()
      local pt, gdx, gdy = findGrabPoint(win)
      if not pt then
        gdx, gdy = math.floor(f.w / 2), GRAB_DY_FALLBACK
        pt = hs.geometry.point(f.x + gdx, f.y + gdy)
        print(string.format(
          "SpaceSaver(space_move): %s に掴める点が見つかりません。中央 (+%d,+%d) で試します",
          bundleIDOf(win), gdx, gdy))
      end
      local ptD = hs.geometry.point(pt.x + 1, pt.y)

      hs.mouse.absolutePosition(pt)
      hs.eventtap.event.newMouseEvent(
        hs.eventtap.event.types.leftMouseDown, pt):post()
      mouseIsDown = true

      later(DOWN_DELAY, function()
        -- 1px ドラッグでウィンドウをつかんでいる状態を OS に認識させる
        hs.eventtap.event.newMouseEvent(
          hs.eventtap.event.types.leftMouseDragged, ptD)
          :setProperty(hs.eventtap.event.properties.mouseEventDeltaX, 1)
          :post()

        later(DRAG_DELAY, function()
          local function sendKey(n)
            if n > steps then
              -- マウスを放す → フレーム復元
              hs.eventtap.event.newMouseEvent(
                hs.eventtap.event.types.leftMouseUp,
                hs.mouse.absolutePosition()):post()
              mouseIsDown = false

              later(DROP_DELAY, function()
                applyFrame(win, frame)
                -- 合成マウスイベントでウィンドウを掴めていないと、
                -- Space だけが切り替わって取り残される。実際に移れたか検算する
                if indexOf(windowSpacesOf(win), targetSid) then
                  dragFailures[bundleIDOf(win)] = 0
                  finish("drag")
                else
                  noteDragFailure(win, string.format(
                    "Space の切替について来ない, 把持点=+%d,+%d", gdx, gdy))
                  finish("failed")
                end
              end)
              return
            end
            -- ドラッグ保持中にショートカット送出（1 Space ずつ移動）
            postHotkey(hk[dir])
            later(KEY_DELAY, function() sendKey(n + 1) end)
          end

          sendKey(1)
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

  -- どちらの手段も無効と判明している場合、Space を切り替えずフレームだけ合わせる
  if nativeMoveWorks == false and dragBlocked[bundleIDOf(win)] then
    applyFrame(win, frame)
    later(0, function() done("unsupported") end)
    return
  end

  if nativeMoveWorks == false then
    dragWindowToSpace(win, targetSid, frame, hotkeys, done)
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
      dragWindowToSpace(win, targetSid, frame, hotkeys, done)
    end
  end)
end

return M
