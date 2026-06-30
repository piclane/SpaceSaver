--[[
  sequoia_move.lua — SpaceSaver Spoon 内部モジュール
  -------------------------------------------------------
  macOS 15 (Sequoia) 専用の moveWindowToSpace 代替実装。

  hs.spaces.moveWindowToSpace が Sequoia では動作しないため
  (Hammerspoon issue #3698)、以下の方式で代替する:
    1. ウィンドウのタイトルバーをマウスでつかむ（leftMouseDown + 1px drag）
    2. ドラッグ保持中に「操作スペースを左/右に移動」ショートカットを送出
    3. mouseUp 後、ウィンドウフレームを正確な位置に補正

  参考: https://gist.github.com/xgungnir/a02f059b29adacaf7df884920e127533

  公開インターフェース:
    M.isSequoia()                                     -> bool
    M.moveWindowToSpace(win, sid, frame, hotkeys, done)
      win     : hs.window
      sid     : 目的 Space ID
      frame   : {x,y,w,h} 最終フレーム（nil 可）
      hotkeys : { left={{mods},key}, right={{mods},key} }
      done    : 完了コールバック（常に1回だけ呼ばれる）
--]]

local M = {}

-- ============================================================
-- タイミング定数（Gist のタイミングを踏襲）
-- ============================================================

local TITLE_DX   = 5     -- タイトルバー把持点の x オフセット
local TITLE_DY   = 18    -- 同 y オフセット（タイトルバー高さ相当）
local GOTO_DELAY = 0.5   -- gotoSpace 後、ウィンドウ把持までの待機（秒）
local DOWN_DELAY = 0.03  -- mouseDown 後（秒）
local DRAG_DELAY = 0.05  -- 1px ドラッグ確立後（秒）
local KEY_DELAY  = 0.6   -- 各ショートカット送出後（Space 切替アニメ待ち）（秒）
local DROP_DELAY = 0.1   -- mouseUp 後、フレーム復元まで（秒）
local TIMEOUT    = 2.0   -- 1 ウィンドウあたりの安全タイムアウト（秒）

-- ============================================================
-- ユーティリティ
-- ============================================================

-- ipairs テーブルから値のインデックスを返す（なければ nil）
local function indexOf(tbl, val)
  for i, v in ipairs(tbl) do
    if v == val then return i end
  end
  return nil
end

-- ============================================================
-- 公開 API
-- ============================================================

--- macOS 15.x (Sequoia) かどうかを返す
function M.isSequoia()
  local v = hs.host.operatingSystemVersion()
  return v ~= nil and v.major == 15
end

-- ============================================================
-- ドラッグ方式 Space 移動（Sequoia 専用内部実装）
-- ============================================================

-- win を targetSid の Space へドラッグ方式で移動する。
-- 完了時（成功・失敗・タイムアウト問わず）に done() を必ず1回だけ呼ぶ。
local function dragWindowToSpace(win, targetSid, frame, hotkeys, done)
  local called = false
  local timeoutTimer = nil

  -- 完了クロージャ（多重呼び出し防止）
  local function finish()
    if called then return end
    called = true
    if timeoutTimer then timeoutTimer:stop(); timeoutTimer = nil end
    done()
  end

  -- フェイルセーフ: TIMEOUT 秒後に強制完了（復元全体が止まらないよう）
  timeoutTimer = hs.timer.doAfter(TIMEOUT, function()
    print("SpaceSaver(sequoia_move): タイムアウト — 強制完了")
    finish()
  end)

  -- Step 4〜7: curSid / curIdx / targetIdx が確定した後のドラッグ本体
  local function performDrag(curSid, allSpaces, curIdx, targetIdx)
    -- 既に目的 Space にいる場合はフレーム補正のみ
    if curIdx == targetIdx then
      if frame then
        pcall(function()
          win:setFrame(hs.geometry.rect(frame.x, frame.y, frame.w, frame.h))
        end)
      end
      finish()
      return
    end

    -- Step 4: 現在 Space に移動してウィンドウを最前面化
    pcall(hs.spaces.gotoSpace, curSid)
    hs.timer.doAfter(GOTO_DELAY, function()
      pcall(function() win:raise() end)

      -- Step 5: タイトルバーをつかむ（mouseDown + 1px drag）
      local f   = win:frame()
      local pt  = hs.geometry.point(f.x + TITLE_DX, f.y + TITLE_DY)
      local ptD = hs.geometry.point(pt.x + 1, pt.y)

      hs.mouse.absolutePosition(pt)
      hs.eventtap.event.newMouseEvent(
        hs.eventtap.event.types.leftMouseDown, pt):post()

      hs.timer.doAfter(DOWN_DELAY, function()
        -- 1px ドラッグでウィンドウをつかんでいる状態を OS に認識させる
        hs.eventtap.event.newMouseEvent(
          hs.eventtap.event.types.leftMouseDragged, ptD)
          :setProperty(hs.eventtap.event.properties.mouseEventDeltaX, 1)
          :post()

        hs.timer.doAfter(DRAG_DELAY, function()
          -- Step 6: Space 切替ショートカットを steps 回送出
          local steps = math.abs(targetIdx - curIdx)
          local hk    = targetIdx > curIdx and hotkeys.right or hotkeys.left

          local function sendKey(n)
            if n > steps then
              -- Step 7: マウスを放す → フレーム復元
              local ptUp = hs.mouse.absolutePosition()
              hs.eventtap.event.newMouseEvent(
                hs.eventtap.event.types.leftMouseUp, ptUp):post()

              hs.timer.doAfter(DROP_DELAY, function()
                if frame then
                  pcall(function()
                    win:setFrame(hs.geometry.rect(
                      frame.x, frame.y, frame.w, frame.h))
                  end)
                end
                finish()
              end)
              return
            end
            -- ドラッグ保持中にショートカット送出（1 Space ずつ移動）
            hs.eventtap.keyStroke(hk[1], hk[2])
            hs.timer.doAfter(KEY_DELAY, function() sendKey(n + 1) end)
          end

          sendKey(1)
        end)
      end)
    end)
  end

  -- ============================================================
  -- Step 1 & 2: 目的スクリーン・インデックス・現在 Space を特定
  -- ============================================================

  -- 目的 Space が属するスクリーンの UUID と、そのスクリーンの Space 配列を取得
  local screenUUID = hs.spaces.spaceDisplay(targetSid)
  if not screenUUID then
    print("SpaceSaver(sequoia_move): spaceDisplay 失敗 sid=" .. tostring(targetSid))
    finish(); return
  end

  local allSpaces = hs.spaces.spacesForScreen(screenUUID) or {}
  local targetIdx = indexOf(allSpaces, targetSid)
  if not targetIdx then
    print("SpaceSaver(sequoia_move): targetSid が spacesForScreen に見つからない")
    finish(); return
  end

  -- ウィンドウが現在いる Space を、目的スクリーンの allSpaces から探す
  local curSid = nil
  local wok, winSpaces = pcall(hs.spaces.windowSpaces, win)
  if wok and winSpaces then
    for _, s in ipairs(winSpaces) do
      if indexOf(allSpaces, s) then curSid = s; break end
    end
  end

  if curSid then
    -- 同一スクリーン上にある（通常ケース）
    local curIdx = indexOf(allSpaces, curSid)
    if not curIdx then
      print("SpaceSaver(sequoia_move): curSid のインデックス不明")
      finish(); return
    end
    performDrag(curSid, allSpaces, curIdx, targetIdx)
  else
    -- 別スクリーン上にある（cross-screen）:
    -- setFrame で目的スクリーンへ寄せ、activeSpaceOnScreen で現在 Space を取得
    if frame then
      pcall(function()
        win:setFrame(hs.geometry.rect(frame.x, frame.y, frame.w, frame.h))
      end)
    end
    hs.timer.doAfter(0.1, function()
      local ok2, cs = pcall(hs.spaces.activeSpaceOnScreen, screenUUID)
      if not ok2 or not cs then
        print("SpaceSaver(sequoia_move): cross-screen 現在 Space 特定失敗")
        finish(); return
      end
      local ci = indexOf(allSpaces, cs)
      if not ci then
        print("SpaceSaver(sequoia_move): cross-screen curSid のインデックス不明")
        finish(); return
      end
      performDrag(cs, allSpaces, ci, targetIdx)
    end)
  end
end

-- ============================================================
-- 公開: OS を自動判定してウィンドウを Space へ移動する
-- ============================================================

--- macOS 15.x: ドラッグ方式 / それ以外: hs.spaces.moveWindowToSpace
--- done() は常に1回だけ呼ばれる（Sequoia は非同期・非Sequoia はほぼ即時）。
function M.moveWindowToSpace(win, targetSid, frame, hotkeys, done)
  if M.isSequoia() then
    dragWindowToSpace(win, targetSid, frame, hotkeys, done)
  else
    pcall(function()
      hs.spaces.moveWindowToSpace(win, targetSid, true)
      if frame then
        win:setFrame(hs.geometry.rect(frame.x, frame.y, frame.w, frame.h))
      end
    end)
    -- doAfter(0) で再帰スタック増大を防ぎつつ次タスクへ
    hs.timer.doAfter(0, done)
  end
end

return M
