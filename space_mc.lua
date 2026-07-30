--[[
  space_mc.lua — SpaceSaver Spoon 内部モジュール
  -------------------------------------------------------
  Mission Control 上でウィンドウのサムネイルを掴み、Space のサムネイルへ落として
  別の Space へ移す。人が手でやる操作をそのままなぞる。

  タイトルバーを掴む方式（space_move.lua）が効かないアプリのための代替手段。
  Excel や LINE は掴めてはいるのに Space の切替について来ない。ドラッグを
  アプリ自身が処理していてウィンドウサーバ側に「ドラッグ中のウィンドウ」が
  無いためと思われる。Mission Control は Dock が処理するので、この違いを受けない。

  移動にかかる時間は距離によらず一定（実測 1.8 秒前後）なので、
  離れた Space へ移すときは 1 Space ずつ送るより速い。

  つまずきやすい点:
    - hs.mouse.absolutePosition はカーソルをワープさせるだけで mouseMoved を
      出さない。それではホバーが付かず、サムネイルを掴めない。
      枠の外から中へ mouseMoved を出しながら入る
    - AX ツリーは Mission Control のアニメーション途中で既に埋まる。
      子要素の有無で開き終わりを判断すると、まだ動いているサムネイルを
      掴もうとして失敗する。座標が止まるまで待つ
    - ドラッグ中はカーソルの位置に「新規フルスクリーン用の仮枠」が差し込まれ、
      Space サムネイルの番号が 1 つずれる。しかも仮枠はカーソルと一緒に動く。
      番号ではなく名前で狙う

  公開インターフェース:
    M.moveWindowToSpace(win, targetSid, done)
      win       : hs.window
      targetSid : 目的 Space ID
      done      : 完了コールバック。常に1回だけ done(成功したか) で呼ばれる
--]]

local M = {}

-- ============================================================
-- タイミング定数
-- ============================================================

-- 長い待ちは状態を見て進める。固定で待つのは、状態から終わりを判断できない
-- ところだけにする
local POLL_STEP     = 0.05 -- 状態を見に行く間隔（秒）
local OPEN_TIMEOUT  = 2.0  -- Mission Control が開くのを待つ上限（秒）
local BAR_TIMEOUT   = 1.5  -- Space バーが開くのを待つ上限（秒）
local DROP_TIMEOUT  = 1.5  -- 落とした結果が反映されるのを待つ上限（秒）
local CLOSE_TIMEOUT = 1.5  -- Mission Control が閉じるのを待つ上限（秒）
local SPACE_TIMEOUT = 2.0  -- Space 切替の完了を待つ上限（秒）

local SPACE_SETTLE  = 0.35 -- Space 切替後、Mission Control を開くまで（秒）
local DOWN_HOLD     = 0.2  -- 押してからドラッグ開始まで（秒）
local AIM_SETTLE    = 0.18 -- 狙いを直した後、座標を読み直すまで（秒）
local DROP_HOLD     = 0.25 -- 落とす直前の静止（秒）
local AFTER_CLOSE   = 0.25 -- Mission Control を閉じた後（秒）

-- マウスイベントの連なりは短いので、その場で送り切る（最長でも 0.3 秒ほど）
local HOVER_STEPS   = 5    -- 枠の外から中へ入る mouseMoved の回数
local HOVER_HOLD    = 0.03
local HOVER_OUTSIDE = 40   -- 枠の何 px 外から入るか
local DRAG_STEPS    = 10   -- サムネイルを Space バーへ運ぶ分割数
local DRAG_HOLD     = 0.03
local AIM_STEPS     = 5    -- 狙いを直すときの分割数
local AIM_TRIES     = 4    -- 狙いを直す回数の上限

local TITLE_MATCH   = 12   -- サムネイルの照合に使うタイトルの先頭文字数

-- ============================================================
-- ユーティリティ
-- ============================================================

-- hs.timer.doAfter は戻り値を保持しないとタイマーが GC され、
-- コールバックが呼ばれないまま処理が止まる。発火するまで参照を持つ
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

local function sleep(s)
  if s and s > 0 then hs.timer.usleep(math.floor(s * 1000000)) end
end

-- fn() が真を返すまで見に行く。返したら cb(true)、時間切れなら cb(false)
local function pollUntil(fn, timeout, cb)
  local t0 = hs.timer.secondsSinceEpoch()
  local function step()
    local ok, v = pcall(fn)
    if ok and v then cb(true); return end
    if hs.timer.secondsSinceEpoch() - t0 > timeout then cb(false); return end
    later(POLL_STEP, step)
  end
  step()
end

local function indexOf(tbl, val)
  for i, v in ipairs(tbl) do
    if v == val then return i end
  end
  return nil
end

local function windowSpacesOf(win)
  local ok, r = pcall(hs.spaces.windowSpaces, win)
  if ok and type(r) == "table" then return r end
  return {}
end

-- ============================================================
-- Mission Control の AX 要素
-- ============================================================

-- 指定モニタの mc.display 要素を返す（見つからなければ nil）
local function mcDisplay(screenID)
  local apps = hs.application.applicationsForBundleID("com.apple.dock")
  local dock = apps and apps[1]
  if not dock then return nil end
  for _, v in ipairs(hs.axuielement.applicationElement(dock)) do
    if v.AXIdentifier == "mc" then
      for _, d in ipairs(v:attributeValue("AXChildren") or {}) do
        if d.AXIdentifier == "mc.display" and d.AXDisplayID == screenID then return d end
      end
    end
  end
  return nil
end

local function groupNamed(disp, ident)
  for _, g in ipairs(disp and disp:attributeValue("AXChildren") or {}) do
    if g.AXIdentifier == ident then return g end
  end
  return nil
end

-- その Space に並ぶウィンドウのサムネイル（AXButton）を返す
local function windowThumbs(disp)
  local g = groupNamed(disp, "mc.windows")
  return (g and g:attributeValue("AXChildren")) or {}
end

-- 画面上部の Space サムネイル（AXButton）を並び順に返す
local function spaceThumbs(disp)
  local g = groupNamed(disp, "mc.spaces")
  for _, s in ipairs(g and g:attributeValue("AXChildren") or {}) do
    if s.AXIdentifier == "mc.spaces.list" then
      return s:attributeValue("AXChildren") or {}
    end
  end
  return {}
end

local function titleOf(el)
  local ok, t = pcall(function() return el:attributeValue("AXTitle") end)
  return (ok and t) and tostring(t) or ""
end

local function frameOf(el)
  local ok, f = pcall(function() return el:attributeValue("AXFrame") end)
  return (ok and type(f) == "table") and f or nil
end

-- 名前が一致する Space サムネイルを返す
local function spaceThumbNamed(disp, name)
  for _, b in ipairs(spaceThumbs(disp)) do
    if titleOf(b) == name then return b end
  end
  return nil
end

-- サムネイルの座標をまとめた文字列。動きが止まったかの判定に使う
local function thumbSignature(disp)
  local list = windowThumbs(disp)
  if #list == 0 then return nil end
  local t = {}
  for i, b in ipairs(list) do
    local f = frameOf(b)
    t[i] = f and string.format("%d,%d", math.floor(f.x), math.floor(f.y)) or "?"
  end
  return table.concat(t, "|")
end

-- ============================================================
-- マウス操作
-- ============================================================

local ev = hs.eventtap.event

local function postAt(kind, pt, dx, dy)
  local e = ev.newMouseEvent(kind, pt)
  if dx then e:setProperty(ev.properties.mouseEventDeltaX, math.floor(dx)) end
  if dy then e:setProperty(ev.properties.mouseEventDeltaY, math.floor(dy)) end
  e:post()
end

-- 枠の外から中へ mouseMoved を出しながら入る。
-- これでホバーが付き、サムネイルを掴めるようになる
local function hoverInto(fromX, fromY, toX, toY)
  hs.mouse.absolutePosition(hs.geometry.point(fromX, fromY))
  for i = 1, HOVER_STEPS do
    local t = i / HOVER_STEPS
    postAt(ev.types.mouseMoved,
      hs.geometry.point(fromX + (toX - fromX) * t, fromY + (toY - fromY) * t))
    sleep(HOVER_HOLD)
  end
end

-- ============================================================
-- 公開 API
-- ============================================================

--- win を Mission Control 経由で targetSid の Space へ移す。
--- done(ok) は常に1回だけ呼ばれる。
function M.moveWindowToSpace(win, targetSid, done)
  local called      = false
  local mouseIsDown = false
  local curX, curY  = 0, 0

  local screenUUID = hs.spaces.spaceDisplay(targetSid)
  local screen     = screenUUID and hs.screen.find(screenUUID)
  if not screen then
    later(0, function() done(false) end)
    return
  end
  local ff       = screen:fullFrame()
  local screenID = screen:id()
  local allSpaces = hs.spaces.spacesForScreen(screenUUID) or {}
  local targetIdx = indexOf(allSpaces, targetSid)
  if not targetIdx then
    later(0, function() done(false) end)
    return
  end

  local home = windowSpacesOf(win)[1]

  -- 中断してもマウスを押したままにしない。Mission Control も開いたままにしない
  local function finish(ok)
    if called then return end
    called = true
    if mouseIsDown then
      pcall(function()
        postAt(ev.types.leftMouseUp, hs.mouse.absolutePosition())
      end)
      mouseIsDown = false
    end
    pcall(hs.spaces.closeMissionControl)
    pollUntil(function() return mcDisplay(screenID) == nil end, CLOSE_TIMEOUT, function()
      later(AFTER_CLOSE, function()
        -- 落とし損ねてフルスクリーンになっていたら戻す
        local isFS = false
        pcall(function() isFS = win:isFullScreen() end)
        if isFS then
          pcall(function() win:setFullScreen(false) end)
          later(1.0, function() done(ok and indexOf(windowSpacesOf(win), targetSid) ~= nil) end)
          return
        end
        done(ok and indexOf(windowSpacesOf(win), targetSid) ~= nil)
      end)
    end)
  end

  local function dragTo(x, y, steps)
    local sx, sy = curX, curY
    for i = 1, steps do
      local t = i / steps
      local nx, ny = sx + (x - sx) * t, sy + (y - sy) * t
      postAt(ev.types.leftMouseDragged, hs.geometry.point(nx, ny), nx - curX, ny - curY)
      curX, curY = nx, ny
      sleep(DRAG_HOLD)
    end
  end

  -- ------------------------------------------------------------
  -- Mission Control を開いてサムネイルを掴み、目的の Space へ落とす
  -- ------------------------------------------------------------
  local function grabAndDrop(disp)
    local title = win:title() or ""
    local thumb
    for _, b in ipairs(windowThumbs(disp)) do
      local t = titleOf(b)
      if t ~= "" and (t == title or t:sub(1, TITLE_MATCH) == title:sub(1, TITLE_MATCH)) then
        thumb = b; break
      end
    end
    if not thumb then
      print("SpaceSaver(space_mc): Mission Control にウィンドウのサムネイルが無い")
      finish(false); return
    end
    local wf = frameOf(thumb)
    if not wf then finish(false); return end
    local cx, cy = wf.x + wf.w / 2, wf.y + wf.h / 2

    -- Space バーは閉じていても名前は読める。座標だけが当てにならないので、
    -- 名前を控えておき、落とす直前に座標を読み直す
    local names, aimX = {}, ff.x + ff.w / 2
    for i, b in ipairs(spaceThumbs(disp)) do
      names[i] = titleOf(b)
      if i == targetIdx then
        local f = frameOf(b)
        if f then aimX = f.x + f.w / 2 end
      end
    end
    local wantName = names[targetIdx]
    if not wantName or wantName == "" then
      print("SpaceSaver(space_mc): 目的 Space のサムネイル名を読めない")
      finish(false); return
    end

    hoverInto(math.max(ff.x + 2, wf.x - HOVER_OUTSIDE), cy, cx, cy)
    curX, curY = cx, cy
    postAt(ev.types.leftMouseDown, hs.geometry.point(cx, cy))
    mouseIsDown = true

    later(DOWN_HOLD, function()
      -- 画面上端の中央を経由せず、目的のサムネイルへ斜めに直行する。
      -- 中央にはドラッグ中だけ仮枠ができるので、そこへ落とすと
      -- 新しいフルスクリーン Space が作られてしまう
      dragTo(aimX, ff.y + 45, DRAG_STEPS)

      -- バーが開いて座標が使えるようになるのを待つ
      pollUntil(function()
        local f = frameOf(spaceThumbNamed(disp, wantName))
        return f and f.y >= ff.y
      end, BAR_TIMEOUT, function(opened)
        if not opened then
          print("SpaceSaver(space_mc): Space バーが開かない")
          finish(false); return
        end

        -- カーソルが目的の枠に入るまで寄せ直す。
        -- 仮枠が差し込まれるぶん、狙った位置は動く
        local tries = 0
        local function aim()
          tries = tries + 1
          local f = frameOf(spaceThumbNamed(disp, wantName))
          if not f or f.y < ff.y then
            if tries >= AIM_TRIES then finish(false); return end
            later(AIM_SETTLE, aim); return
          end
          if curX >= f.x + 8 and curX <= f.x + f.w - 8 then
            later(DROP_HOLD, function()
              postAt(ev.types.leftMouseUp, hs.geometry.point(curX, curY))
              mouseIsDown = false
              -- 反映されるまで待つ
              pollUntil(function()
                return windowSpacesOf(win)[1] ~= home
              end, DROP_TIMEOUT, function() finish(true) end)
            end)
            return
          end
          if tries >= AIM_TRIES then
            print("SpaceSaver(space_mc): 目的 Space のサムネイルに寄せられない")
            finish(false); return
          end
          dragTo(f.x + f.w / 2, f.y + f.h / 2, AIM_STEPS)
          later(AIM_SETTLE, aim)
        end
        aim()
      end)
    end)
  end

  -- ------------------------------------------------------------
  -- Mission Control を開く
  -- ------------------------------------------------------------
  local function openThen(attempt)
    -- 掴む前にカーソルをサムネイル群から離しておく。
    -- 開いた瞬間にサムネイルへ乗っていると、動かすまでホバーが付かない
    hs.mouse.absolutePosition(hs.geometry.point(ff.x + ff.w / 2, ff.y + ff.h - 120))
    pcall(hs.spaces.openMissionControl)

    local prevSig
    pollUntil(function()
      local disp = mcDisplay(screenID)
      local s = disp and thumbSignature(disp)
      -- 座標が2回続けて同じなら、アニメーションが終わっている
      if s and s == prevSig then return true end
      prevSig = s
      return false
    end, OPEN_TIMEOUT, function(ok)
      local disp = mcDisplay(screenID)
      if ok and disp then grabAndDrop(disp); return end
      -- Space 切替の直後などで効かないことがある。1度だけ送り直す
      if attempt < 2 then openThen(attempt + 1); return end
      print("SpaceSaver(space_mc): Mission Control が開かない")
      finish(false)
    end)
  end

  -- ------------------------------------------------------------
  -- 開始: Mission Control はその Space のウィンドウしか並べないので、
  -- ウィンドウのいる Space を表示してから開く
  -- ------------------------------------------------------------
  if not home then
    later(0, function() done(false) end)
    return
  end
  if indexOf(windowSpacesOf(win), targetSid) then
    later(0, function() done(true) end)
    return
  end

  local aok, active = pcall(hs.spaces.activeSpaceOnScreen, screenUUID)
  if aok and active == home then
    openThen(1)
  else
    pcall(hs.spaces.gotoSpace, home)
    pollUntil(function()
      local o, a = pcall(hs.spaces.activeSpaceOnScreen, screenUUID)
      return o and a == home
    end, SPACE_TIMEOUT, function()
      later(SPACE_SETTLE, function() openThen(1) end)
    end)
  end
end

return M
