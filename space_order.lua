--[[
  space_order.lua — SpaceSaver Spoon 内部モジュール
  -------------------------------------------------------
  スクリーン内の Space の並び順を整える。

  フルスクリーン Space は、ウィンドウを全画面化したときに必ずその画面の
  末尾に作られる。元ウィンドウがどの Space に居たかは影響しない。
  hs.spaces には並び替えの API がなく、Mission Control 上の Space サムネイル
  (AXButton) も AXPress と AXRemoveDesktop しか持たない。
  そこで、サムネイルの AXFrame を取り出してマウスドラッグで並べ替える。

  ドラッグの着地位置は方向で 1 ずれる。
    右へ動かす: つまみ上げた分だけ後続が左へ詰まるので、1つ先の位置へ落とす
    左へ動かす: ずれないのでそのままの位置へ落とす

  公開インターフェース:
    M.arrange(screenUUID, targets, done)
      screenUUID : 対象スクリーンの UUID
      targets    : { {sid=<SpaceID>, index=<1始まりの目標位置>}, ... }
                   index の昇順であること
      done       : 完了コールバック。実際に動かした回数を引数に1回だけ呼ばれる
                   並べ替えが不要なら Mission Control を開かずに done(0) を呼ぶ
--]]

local M = {}

-- ============================================================
-- タイミング定数
-- ============================================================

local OPEN_DELAY   = 1.0  -- Mission Control を開いた後、最初に AX を読むまで（秒）
local STABLE_STEP  = 0.3  -- サムネイル座標の安定判定の間隔（秒）
local STABLE_TRIES = 12   -- 同上の最大試行回数
local HOVER_DELAY  = 0.6  -- カーソルを上端へ置いてから（秒）
local HOVER_STEPS  = 20   -- 上端へ入るときに送る mouseMoved の回数
local HOVER_HOLD   = 0.02 -- 同上の1回あたりの間隔（秒）
local GRAB_DELAY  = 0.5   -- マウス移動後、押下まで（秒）
local DOWN_DELAY  = 0.5   -- 押下後、ドラッグ開始まで（秒）
local DRAG_STEP   = 0.05  -- ドラッグ1コマあたり（秒）
local DRAG_STEPS  = 15    -- ドラッグの分割数
local SETTLE      = 1.2   -- ドラッグ後、並びが確定するまで（秒）
local CLOSE_DELAY = 1.0   -- Mission Control を閉じた後（秒）

-- ============================================================
-- ユーティリティ
-- ============================================================

-- hs.timer.doAfter は戻り値を保持しないとタイマーが GC され、
-- コールバックが呼ばれないまま処理が止まる。発火するまで参照を持つ。
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

local function indexOf(tbl, val)
  for i, v in ipairs(tbl) do
    if v == val then return i end
  end
  return nil
end

local function currentOrder(screenUUID)
  local ok, r = pcall(hs.spaces.spacesForScreen, screenUUID)
  if ok and type(r) == "table" then return r end
  return {}
end

-- Mission Control の Space 一覧 (mc.spaces.list) の子要素を返す。
-- hs.spaces が removeSpace などで辿るのと同じ経路で、並び順は
-- spacesForScreen と一致する。
local function spacesListElements(screenID)
  local apps = hs.application.applicationsForBundleID("com.apple.dock")
  local dock = apps and apps[1]
  if not dock then return {} end

  for _, v in ipairs(hs.axuielement.applicationElement(dock)) do
    if v.AXIdentifier == "mc" then
      for _, disp in ipairs(v:attributeValue("AXChildren") or {}) do
        if disp.AXIdentifier == "mc.display" and disp.AXDisplayID == screenID then
          for _, grp in ipairs(disp:attributeValue("AXChildren") or {}) do
            if grp.AXIdentifier == "mc.spaces" then
              for _, sub in ipairs(grp:attributeValue("AXChildren") or {}) do
                if sub.AXIdentifier == "mc.spaces.list" then
                  return sub:attributeValue("AXChildren") or {}
                end
              end
            end
          end
        end
      end
    end
  end
  return {}
end

-- Mission Control を開いた直後はサムネイルがまだ動いており、
-- その途中の AXFrame でドラッグするとカーソルが的を外す。
-- 座標が2回続けて同じになるまで待ってから使う。
local function framesSignature(list)
  local t = {}
  for i, e in ipairs(list) do
    local f = e:attributeValue("AXFrame")
    -- Retina では座標が 784.5 のような小数になる。%d は小数を整数化できず
    -- 例外を投げるので、必ず math.floor を通す。
    -- ここで投げると waitForStableList のコールバック連鎖が止まり、
    -- 並べ替えの done が呼ばれないまま復元が終わらなくなる
    t[i] = f and string.format("%d,%d,%d,%d",
      math.floor(f.x), math.floor(f.y), math.floor(f.w), math.floor(f.h)) or "?"
  end
  return table.concat(t, "|")
end

-- 診断用。AXFrame を読める形にする（小数をそのまま出す）
local function fmtFrame(f)
  if not f then return "nil" end
  return string.format("x=%g y=%g w=%g h=%g", f.x, f.y, f.w, f.h)
end

-- 診断用。読めなければ nil を返す（例外を診断の途中で投げないため）
local function attrOf(el, name)
  local ok, v = pcall(function() return el:attributeValue(name) end)
  return ok and v or nil
end

-- Mission Control の Space バーは、カーソルがその画面の上端に無いと
-- 小さいピル表示のままで、サムネイルの AXFrame は画面の外（負の y）を指す。
-- AX の値に頼らず、画面の矩形から上端中央へカーソルを移す。
--
-- hs.mouse.absolutePosition はカーソルをワープさせるだけで mouseMoved を出さない。
-- それではホバーが付かず、バーは畳まれたままで座標が使えない。
-- 下から上端へ mouseMoved を送りながら入る（space_mc.lua の hoverInto と同じ考え方）
local ev = hs.eventtap.event

local function hoverTopOfScreen(screenUUID)
  local scr = hs.screen.find(screenUUID)
  if not scr then return end
  local f = scr:fullFrame()
  local x     = f.x + f.w / 2
  local fromY = f.y + math.min(300, f.h / 3)
  local toY   = f.y + 5
  hs.mouse.absolutePosition(hs.geometry.point(x, fromY))
  local prevY = fromY
  for i = 1, HOVER_STEPS do
    local y = fromY + (toY - fromY) * (i / HOVER_STEPS)
    local e = ev.newMouseEvent(ev.types.mouseMoved, hs.geometry.point(x, y))
    e:setProperty(ev.properties.mouseEventDeltaX, 0)
    e:setProperty(ev.properties.mouseEventDeltaY, math.floor(y - prevY))
    e:post()
    prevY = y
    hs.timer.usleep(math.floor(HOVER_HOLD * 1000000))
  end
end

-- サムネイルの座標がすべて対象モニタの矩形内にあるか。
-- Space バーが展開していないと別モニタの座標が返ることがあり、
-- そのまま掴むと関係のない画面をドラッグしてしまう。
-- 第2戻り値に、外れた理由を診断用の文字列で返す（呼び出し側はログにだけ使う）
local function framesOnScreen(list, screenUUID)
  local scr = hs.screen.find(screenUUID)
  if not scr then return false, "画面が見つからない" end
  if #list == 0 then return false, "サムネイルが0件" end
  local sf = scr:fullFrame()
  for i, e in ipairs(list) do
    local f = e:attributeValue("AXFrame")
    if not f then
      return false, string.format("[%d] の AXFrame が読めない", i)
    end
    local cx, cy = f.x + f.w / 2, f.y + f.h / 2
    if cx < sf.x or cx > sf.x + sf.w or cy < sf.y or cy > sf.y + sf.h then
      return false, string.format("[%d] の中心 (%g,%g) が画面 %s の外",
        i, cx, cy, fmtFrame(sf))
    end
  end
  return true, nil
end

-- 座標が2回続けて同じで、かつ対象モニタ内に収まるまで待つ。
-- AX の読み取りは pcall で囲む。ここで例外を投げると cb が呼ばれず、
-- 呼び出し側の連鎖が止まって復元が終わらなくなる。
-- 最後に外れた理由は lastReason に控え、時間切れのときログに出す
local lastReason = nil

local function waitForStableList(screenID, screenUUID, tries, prev, cb)
  local ok, list, sig = pcall(function()
    local l = spacesListElements(screenID)
    return l, framesSignature(l)
  end)
  if not ok then
    lastReason = "AX の読み取りで例外: " .. tostring(list)
    print("SpaceSaver(space_order): " .. lastReason)
    cb({}, true); return
  end

  local onScreen, why = framesOnScreen(list, screenUUID)
  if not onScreen then lastReason = why end
  if #list > 0 and sig == prev and onScreen then
    lastReason = nil
    cb(list); return
  end
  if tries <= 0 then cb(list, true); return end
  later(STABLE_STEP, function()
    waitForStableList(screenID, screenUUID, tries - 1, sig, cb)
  end)
end

-- ============================================================
-- サムネイルのドラッグ
-- ============================================================

-- list の要素は等間隔に並ぶ。末尾より後ろへ落とす場合に備え、
-- 存在しない位置の中心 X も間隔から外挿する。
local function slotCenterX(list, idx)
  local last = list[#list]:attributeValue("AXFrame")
  if idx <= #list then
    local f = list[idx]:attributeValue("AXFrame")
    return f and (f.x + f.w / 2) or nil
  end
  if not last then return nil end
  local pitch = last.w
  if #list > 1 then
    local a = list[1]:attributeValue("AXFrame")
    local b = list[2]:attributeValue("AXFrame")
    if a and b then pitch = b.x - a.x end
  end
  return last.x + (idx - #list) * pitch + last.w / 2
end

-- list[from] のサムネイルを位置 to へドラッグする。
-- 中断してもマウスボタンを押したままにしない。
local function dragThumbnail(list, from, to, done)
  local types, props = hs.eventtap.event.types, hs.eventtap.event.properties
  local sf = list[from] and list[from]:attributeValue("AXFrame")
  -- 右へ動かすときだけ 1 つ先へ落とす（後続が左へ詰まるぶんの補正）
  local dropX = slotCenterX(list, to > from and to + 1 or to)
  if not sf or not dropX then done(false); return end

  local p0 = hs.geometry.point(sf.x + sf.w / 2, sf.y + sf.h / 2)
  local p1 = hs.geometry.point(dropX, p0.y)
  local mouseIsDown = false

  local function release()
    if not mouseIsDown then return end
    pcall(function()
      hs.eventtap.event.newMouseEvent(types.leftMouseUp, hs.mouse.absolutePosition()):post()
    end)
    mouseIsDown = false
  end

  hs.mouse.absolutePosition(p0)
  later(GRAB_DELAY, function()
    local ok = pcall(function()
      hs.eventtap.event.newMouseEvent(types.leftMouseDown, p0):post()
    end)
    if not ok then done(false); return end
    mouseIsDown = true

    local dx = math.floor((p1.x - p0.x) / DRAG_STEPS)
    local function move(n)
      if n > DRAG_STEPS then
        pcall(function()
          hs.eventtap.event.newMouseEvent(types.leftMouseUp, p1):post()
        end)
        mouseIsDown = false
        later(SETTLE, function() done(true) end)
        return
      end
      local x = p0.x + (p1.x - p0.x) * n / DRAG_STEPS
      local moved = pcall(function()
        hs.eventtap.event.newMouseEvent(types.leftMouseDragged, hs.geometry.point(x, p0.y))
          :setProperty(props.mouseEventDeltaX, dx):post()
      end)
      if not moved then release(); done(false); return end
      later(DRAG_STEP, function() move(n + 1) end)
    end

    later(DOWN_DELAY, function() move(1) end)
  end)
end

-- ============================================================
-- 公開 API
-- ============================================================

--- targets が指す位置へ Space を並べ替える。
--- done(movedCount) は常に1回だけ呼ばれる。
function M.arrange(screenUUID, targets, done)
  local order = currentOrder(screenUUID)

  -- 並べ替えが要らなければ Mission Control を開かない
  local need = false
  for _, t in ipairs(targets) do
    local cur = indexOf(order, t.sid)
    if cur and cur ~= math.min(t.index, #order) then need = true; break end
  end
  if not need then
    later(0, function() done(0) end)
    return
  end

  local scr = hs.screen.find(screenUUID)
  if not scr then
    later(0, function() done(0) end)
    return
  end
  local screenID = scr:id()
  local moved = 0

  local function finish()
    pcall(hs.spaces.closeMissionControl)
    later(CLOSE_DELAY, function() done(moved) end)
  end

  -- attempt はドラッグの試行回数。取りこぼしがあるので1度だけやり直す
  local function step(i, attempt)
    if i > #targets then finish(); return end

    local ord  = currentOrder(screenUUID)
    local goal = math.min(targets[i].index, #ord)
    local cur  = indexOf(ord, targets[i].sid)
    if not cur or cur == goal then step(i + 1, 1); return end

    hoverTopOfScreen(screenUUID)
    later(HOVER_DELAY, function()
    waitForStableList(screenID, screenUUID, STABLE_TRIES, nil, function(list, timedOut)
      local onScreen, why = framesOnScreen(list, screenUUID)
      if timedOut or not onScreen then
        print(string.format(
          "SpaceSaver(space_order): Space バーの座標が安定しないため並べ替えを中止"
          .. " [診断] 時間切れ=%s 理由=[%s] サムネイル=%d件",
          tostring(timedOut), tostring(why or lastReason), #list))
        for i, e in ipairs(list) do
          print(string.format("  [%d] title=[%s] frame=%s",
            i, tostring(attrOf(e, "AXTitle")), fmtFrame(attrOf(e, "AXFrame"))))
        end
        finish(); return
      end
      if #list ~= #ord then
        print(string.format(
          "SpaceSaver(space_order): Mission Control の Space 一覧が一致しない (%d/%d)。中止",
          #list, #ord))
        finish(); return
      end

      dragThumbnail(list, cur, goal, function(ok)
        if ok and indexOf(currentOrder(screenUUID), targets[i].sid) == goal then
          moved = moved + 1
          step(i + 1, 1)
        elseif attempt < 2 then
          step(i, attempt + 1)
        else
          print(string.format("SpaceSaver(space_order): sid=%s を #%d へ動かせなかった (現在 #%s)",
            tostring(targets[i].sid), goal, tostring(cur)))
          step(i + 1, 1)
        end
      end)
    end)
    end)
  end

  -- hs.spaces.openMissionControl は内部に持つ Mission Control 要素のキャッシュを見て
  -- 開くかどうかを決めるため、実際には開かないことがある。
  -- Space 一覧が取れなければ一度だけ開き直す。
  local function ensureOpen(retried)
    waitForStableList(screenID, screenUUID, STABLE_TRIES, nil, function(list)
      if #list > 0 then step(1, 1); return end
      if retried then
        print("SpaceSaver(space_order): Mission Control を開けなかったため並べ替えを中止")
        later(0, function() done(0) end)
        return
      end
      pcall(hs.spaces.toggleMissionControl)
      later(OPEN_DELAY, function() ensureOpen(true) end)
    end)
  end

  -- 開く前にカーソルを上端へ置くことで、Space バーが展開した状態で表示される
  hoverTopOfScreen(screenUUID)
  pcall(hs.spaces.openMissionControl)
  later(OPEN_DELAY, function() ensureOpen(false) end)
end

return M
