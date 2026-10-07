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
    - ウィンドウのサムネイルが持つタイトルは、ウィンドウサーバーのタイトルである。
      hs.window:title() が返すアクセシビリティ用のタイトルとは、アプリによって違う。
      Chrome は前者にページのタイトルだけを設定し、後者には「<ページのタイトル> -
      固定済み - Google Chrome - <プロファイル名>」のようにタブの状態・アプリ名・
      プロファイル名を足す。照合には前者を使う（hs.window.list で取得する）

  公開インターフェース:
    M.moveWindowToSpace(win, targetSid, done)
      win       : hs.window。目的 Space と同じモニタに置いてから渡すこと。
                  Mission Control は各モニタに、そのモニタで表示中の Space の
                  ウィンドウしか並べないので、別のモニタにあるとサムネイルが見つからない
      targetSid : 目的 Space ID
      done      : 完了コールバック。常に1回だけ done(成功したか, 失敗の区分) で呼ばれる。
                  失敗の区分は次の2つで、成功したときは nil を渡す。
                    "mission-control" Mission Control が開かない、Space バーが出ない
                                      など、どのアプリでも同じように起きる失敗
                    "window"          サムネイルが無い、落としても移動していないなど、
                                      そのウィンドウに固有の失敗
                  呼び出し側は前者をアプリの失敗として数えてはいけない。数えると、
                  Mission Control の一時的な不調で、そのアプリだけが移動手段を失う

    M.isOpen(screenID)
      screenID : hs.screen:id() が返す数値
      指定モニタで Mission Control が開いているかを返す。
      閉じきる前に画面の座標を調べると Dock の要素が返るため、待つ側が使う
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
local PARK_SETTLE   = 0.25 -- サムネイルの外へ退かしてから、掴みに入るまで（秒）
local DRAG_STEPS    = 10   -- サムネイルを Space バーへ運ぶ分割数
local DRAG_HOLD     = 0.03
local AIM_STEPS     = 5    -- 狙いを直すときの分割数
local AIM_TRIES     = 4    -- 狙いを直す回数の上限

-- ウィンドウサーバーのタイトルを取れないときに、アクセシビリティ用のタイトルと
-- サムネイルのタイトルを照合する先頭のバイト数
local TITLE_MATCH   = 12

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

-- win のウィンドウサーバーのタイトルを返す（取れなければ nil）。
-- hs.window.list は表示中のウィンドウしか返さないので、win のいる Space を表示してから呼ぶ。
-- ほかのアプリのタイトルは、Hammerspoon に画面収録の許可がないと返らない
local function serverTitleOf(win)
  local ok, title = pcall(function()
    local id = win:id()
    local list = hs.window.list(true)
    if type(list) ~= "table" then return nil end
    for _, w in ipairs(list) do
      if w.kCGWindowNumber == id then return w.kCGWindowName end
    end
    return nil
  end)
  if ok and type(title) == "string" and title ~= "" then return title end
  return nil
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

--- 指定モニタで Mission Control が開いているかを返す。
--- hs.spaces.gotoSpace は Mission Control を開いて Space のサムネイルを押す実装なので、
--- 戻った直後はまだ描画が残っている。その最中に座標の最前面の要素を調べると
--- Dock の要素が返り、ウィンドウを掴む点が 1 つも見つからない。
--- 待つ側がこの関数で消えたことを確かめてから進む。
function M.isOpen(screenID)
  local ok, d = pcall(mcDisplay, screenID)
  return ok and d ~= nil
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

-- 診断用。AXFrame を読める形にする。%d は小数を整数化できず例外を投げるので %g を使う
local function fmtFrame(f)
  if not f then return "nil" end
  return string.format("x=%g y=%g w=%g h=%g", f.x, f.y, f.w, f.h)
end

-- 画面上部の Space バー（mc.spaces グループ）の枠。畳んでいるときも高さは読める。
-- サムネイルは画面の縮小版なので、バーの高さはモニタの縦横比で変わる。
-- 固定の px を狙うとモニタによって当たらないので、この枠から導く。
-- frameOf を使うので、その宣言より後に置くこと
local function spacesBarFrame(disp)
  local g = groupNamed(disp, "mc.spaces")
  return g and frameOf(g) or nil
end

-- 名前が一致する Space サムネイルを返す
local function spaceThumbNamed(disp, name)
  for _, b in ipairs(spaceThumbs(disp)) do
    if titleOf(b) == name then return b end
  end
  return nil
end

-- win のサムネイルを返す。見つからなければ nil と、診断用の説明を返す。
-- serverTitle（ウィンドウサーバーのタイトル）があれば完全一致で探す。一致が 2 枚以上あると
-- どれが win か見分けられないので、別のウィンドウを移さないよう見つからなかったことにする。
-- serverTitle が無ければアクセシビリティ用のタイトルと先頭 TITLE_MATCH バイトで照合する。
-- 両者が一致するアプリでしか見つからない
local function findWindowThumb(disp, win, serverTitle)
  if serverTitle then
    local found = {}
    for _, b in ipairs(windowThumbs(disp)) do
      if titleOf(b) == serverTitle then found[#found + 1] = b end
    end
    if #found == 1 then return found[1] end
    if #found >= 2 then
      return nil, string.format(
        "同じタイトルのサムネイルが %d 枚あり、どれを移すか決められない 照合=[%s]（ウィンドウサーバー）",
        #found, serverTitle)
    end
    return nil, string.format(
      "Mission Control にウィンドウのサムネイルが無い 照合=[%s]（ウィンドウサーバー）", serverTitle)
  end

  local title = win:title() or ""
  for _, b in ipairs(windowThumbs(disp)) do
    local t = titleOf(b)
    if t ~= "" and (t == title or t:sub(1, TITLE_MATCH) == title:sub(1, TITLE_MATCH)) then
      return b
    end
  end
  return nil, string.format(
    "Mission Control にウィンドウのサムネイルが無い 照合=[%s]（アクセシビリティ。"
    .. "ウィンドウサーバーのタイトルを取れなかった。画面収録の許可を確認すること）", title)
end

-- 点がサムネイルの枠の内側か
local function inFrame(f, x, y)
  return f and x >= f.x and x <= f.x + f.w and y >= f.y and y <= f.y + f.h
end

-- どのウィンドウサムネイルにも載っていない待機点を返す。
-- サムネイルの上でカーソルが止まっていると、そこから動かしても
-- 「入る」遷移が起きず、ホバーが付かないまま掴めない。
-- 画面下端から少しずつ上へ探し、どれにも入らない点を選ぶ
local function parkPoint(disp, ff)
  local frames = {}
  for _, b in ipairs(windowThumbs(disp)) do
    local f = frameOf(b)
    if f then frames[#frames + 1] = f end
  end
  local x = ff.x + ff.w / 2
  for _, y in ipairs({ ff.y + ff.h - 2, ff.y + ff.h - 40, ff.y + 2 }) do
    local free = true
    for _, f in ipairs(frames) do
      if inFrame(f, x, y) then free = false; break end
    end
    if free then return x, y end
  end
  -- どこも空いていなければ、左下の隅を使う（サムネイルは中央寄りに並ぶ）
  return ff.x + 2, ff.y + ff.h - 2
end

-- カーソル位置に中心が一致するサムネイルを探す。
-- 掴めたサムネイルは縮んでカーソルに追従し、中心がカーソルと一致する。
-- 掴めたかどうかを厳密に判定できる（1枚掴むと残りは再レイアウトされるので、
-- 「枠が動いたか」だけでは掴めたかを判定できない）
local function thumbAtCursor(disp, x, y)
  local best, bestD
  for i, b in ipairs(windowThumbs(disp)) do
    local f = frameOf(b)
    if f then
      local dx, dy = (f.x + f.w / 2) - x, (f.y + f.h / 2) - y
      local d = math.sqrt(dx * dx + dy * dy)
      if not bestD or d < bestD then best, bestD = i, d end
    end
  end
  return best, bestD
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
-- これでホバーが付き、サムネイルを掴めるようになる。
-- 移動量 (deltaX/deltaY) も載せる。載せないと Dock がホバーとして扱わないことがある
local function hoverInto(fromX, fromY, toX, toY)
  hs.mouse.absolutePosition(hs.geometry.point(fromX, fromY))
  local px, py = fromX, fromY
  for i = 1, HOVER_STEPS do
    local t = i / HOVER_STEPS
    local x, y = fromX + (toX - fromX) * t, fromY + (toY - fromY) * t
    postAt(ev.types.mouseMoved, hs.geometry.point(x, y), x - px, y - py)
    px, py = x, y
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
  local serverTitle = nil  -- サムネイルの照合に使う。Mission Control を開く前に取得する

  local screenUUID = hs.spaces.spaceDisplay(targetSid)
  local screen     = screenUUID and hs.screen.find(screenUUID)
  if not screen then
    later(0, function() done(false, "mission-control") end)
    return
  end
  local ff       = screen:fullFrame()
  local screenID = screen:id()
  local allSpaces = hs.spaces.spacesForScreen(screenUUID) or {}
  local targetIdx = indexOf(allSpaces, targetSid)
  if not targetIdx then
    later(0, function() done(false, "mission-control") end)
    return
  end

  local home = windowSpacesOf(win)[1]

  -- 中断してもマウスを押したままにしない。Mission Control も開いたままにしない
  local function finish(ok, reason)
    if called then return end
    called = true
    if mouseIsDown then
      pcall(function()
        postAt(ev.types.leftMouseUp, hs.mouse.absolutePosition())
      end)
      mouseIsDown = false
    end
    pcall(hs.spaces.closeMissionControl)
    -- 落とせたつもりでも移動していないことがあるので、最後に所属 Space で検算する。
    -- 検算で落ちた場合は、Mission Control は最後まで動いていたことになるため、
    -- そのウィンドウに固有の失敗として報告する
    local function report()
      local arrived = indexOf(windowSpacesOf(win), targetSid) ~= nil
      if ok and arrived then done(true); return end
      done(false, reason or "window")
    end
    pollUntil(function() return mcDisplay(screenID) == nil end, CLOSE_TIMEOUT, function()
      later(AFTER_CLOSE, function()
        -- 落とし損ねてフルスクリーンになっていたら戻す
        local isFS = false
        pcall(function() isFS = win:isFullScreen() end)
        if isFS then
          pcall(function() win:setFullScreen(false) end)
          later(1.0, report)
          return
        end
        report()
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
    local thumb, why = findWindowThumb(disp, win, serverTitle)
    if not thumb then
      local seen = {}
      for i, b in ipairs(windowThumbs(disp)) do seen[i] = titleOf(b) end
      print(string.format("SpaceSaver(space_mc): %s [診断] 並んでいたサムネイル=[%s]",
        why, table.concat(seen, " | ")))
      finish(false, "window"); return
    end
    local wf = frameOf(thumb)
    if not wf then finish(false, "window"); return end
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
      finish(false, "mission-control"); return
    end

    -- 上端へ運ぶときの縦位置。サムネイルは画面の縮小版なのでバーの高さは
    -- モニタの縦横比で変わる。固定値だとモニタによって外れるため枠から導く
    local bar  = spacesBarFrame(disp)
    local barY = bar and (bar.y + bar.h / 2) or (ff.y + 45)

    -- 掴む前に、どのサムネイルにも載っていない点へ退かす。
    -- Mission Control が開いた時点でカーソルがサムネイルの上にあると、
    -- そこから動かしても「入る」遷移が起きず、ホバーが付かないまま掴めない
    local px, py = parkPoint(disp, ff)
    hs.mouse.absolutePosition(hs.geometry.point(px, py))
    sleep(PARK_SETTLE)

    hoverInto(math.max(ff.x + 2, wf.x - HOVER_OUTSIDE), cy, cx, cy)
    curX, curY = cx, cy
    postAt(ev.types.leftMouseDown, hs.geometry.point(cx, cy))
    mouseIsDown = true

    later(DOWN_HOLD, function()
      -- 画面上端の中央を経由せず、目的のサムネイルへ斜めに直行する。
      -- 中央にはドラッグ中だけ仮枠ができるので、そこへ落とすと
      -- 新しいフルスクリーン Space が作られてしまう
      dragTo(aimX, barY, DRAG_STEPS)

      -- バーが開いて座標が使えるようになるのを待つ。
      -- ドラッグ中に何が見えていたかを控え、時間切れのときに出す
      local lastSeen, sawNil, polls = nil, 0, 0
      pollUntil(function()
        polls = polls + 1
        local f = frameOf(spaceThumbNamed(disp, wantName))
        if f then lastSeen = f else sawNil = sawNil + 1 end
        return f and f.y >= ff.y
      end, BAR_TIMEOUT, function(opened)
        if not opened then
          -- 掴めたサムネイルは縮んでカーソルに追従し、中心がカーソルと一致する。
          -- 1枚掴むと残りは再レイアウトされるので、「枠が動いたか」では判定できない
          local nearIdx, nearD = thumbAtCursor(disp, curX, curY)
          print(string.format(
            "SpaceSaver(space_mc): Space バーが開かない"
            .. " [診断] 目的=[%s] 最後に読めた枠=%s 必要条件 f.y>=%g"
            .. " / 読めなかった回数=%d/%d カーソル=(%g,%g)"
            .. " / 退避点=(%g,%g) 掴んだ枠=%s"
            .. " / カーソル直下のサムネイル=#%s 中心との距離=%s 掴めた=%s",
            wantName, fmtFrame(lastSeen), ff.y, sawNil, polls, curX, curY,
            px, py, fmtFrame(frameOf(thumb)),
            tostring(nearIdx), nearD and string.format("%.1f", nearD) or "nil",
            tostring(nearD ~= nil and nearD < 30)))
          finish(false, "mission-control"); return
        end

        -- カーソルが目的の枠に入るまで寄せ直す。
        -- 仮枠が差し込まれるぶん、狙った位置は動く
        local tries = 0
        local function aim()
          tries = tries + 1
          local f = frameOf(spaceThumbNamed(disp, wantName))
          if not f or f.y < ff.y then
            if tries >= AIM_TRIES then
              print(string.format(
                "SpaceSaver(space_mc): Space バーが展開しないため寄せ直せない"
                .. " 枠=%s 必要条件 f.y>=%g", fmtFrame(f), ff.y))
              finish(false, "mission-control"); return
            end
            later(AIM_SETTLE, aim); return
          end
          -- 縦も見る。バーが展開するとサムネイルは下へ伸びる（実測 y=-32 h=24 →
          -- y=70 h=90）ので、横だけ見て離すと、まだサムネイルの上にいるうちに落とす
          if curX >= f.x + 8 and curX <= f.x + f.w - 8
             and curY >= f.y + 8 and curY <= f.y + f.h - 8 then
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
            print(string.format(
              "SpaceSaver(space_mc): 目的 Space のサムネイルに寄せられない"
              .. " 枠=%s カーソル=(%g,%g) 判定範囲 x=%g..%g y=%g..%g",
              fmtFrame(f), curX, curY,
              f.x + 8, f.x + f.w - 8, f.y + 8, f.y + f.h - 8))
            finish(false, "mission-control"); return
          end
          -- サムネイルの中心へ寄せ直す。バーが展開すると位置も大きさも変わるので、
          -- 掴む前に読んだ座標ではなく、そのつど読み直した枠を使う
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
    -- ウィンドウサーバーのタイトルは、win のいる Space を表示している今のうちに取得する。
    -- hs.window.list は表示中のウィンドウしか返さず、Mission Control を開いたあとも
    -- そう扱われるかは確かめていない
    serverTitle = serverTitle or serverTitleOf(win)

    -- 掴む前にカーソルをサムネイル群から離しておく。
    -- 開いた瞬間にサムネイルへ乗っていると、動かすまでホバーが付かない。
    -- 開く前はまだサムネイルの枠を読めないので画面の下端に置く。
    -- 120px などの決め打ちだと、ウィンドウが多いときサムネイルの中に着地する
    hs.mouse.absolutePosition(hs.geometry.point(ff.x + ff.w / 2, ff.y + ff.h - 2))
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
      finish(false, "mission-control")
    end)
  end

  -- ------------------------------------------------------------
  -- 開始: Mission Control はその Space のウィンドウしか並べないので、
  -- ウィンドウのいる Space を表示してから開く
  -- ------------------------------------------------------------
  if not home then
    later(0, function() done(false, "window") end)
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
