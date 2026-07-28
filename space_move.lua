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

  把持点はウィンドウ上端の中央付近にとる。左端を掴むとリサイズ枠に当たり、
  ウィンドウを横に伸縮させるだけで Space をまたげない。
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

-- タイトルバーの把持点。ウィンドウ上端の中央付近を掴む。
-- 左端 (x+5) はリサイズ枠に当たり、掴んだつもりで横に伸縮させるだけになる。
-- y は Chrome で実測して 2〜6 が有効だった（y+1 はリサイズ枠、y+7 以降はタブ帯）。
-- タブ帯を持つアプリでも、その直上に数 px の掴める帯がある。
local GRAB_DY      = 4     -- タイトルバー把持点の y オフセット
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

-- ドラッグ方式が使えるかはアプリごとに違う。
-- Chrome のようにタイトルバーを自前で描くアプリは、掴めてもウィンドウが
-- Space の切替について来ない（純正 API も効かないので移動手段が無い）。
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

      -- タイトルバーをつかむ（mouseDown + 1px drag）
      local f   = win:frame()
      local pt  = hs.geometry.point(f.x + f.w / 2, f.y + GRAB_DY)
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
                  noteDragFailure(win, "Space の切替について来ない")
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
