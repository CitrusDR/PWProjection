--[[
    pwpr_placed.lua —— "**已经放上去的那一件，投影就不再画**"

    ─────────────────────────────────────────────────────────────────────────
    为什么要有它（2026-09-29 玩家反馈）
    ─────────────────────────────────────────────────────────────────────────
    玩家原话:
      「投影上对应的建筑已经放下了，但是投影还在，会导致实际游戏渲染的彩色
        和投影的蓝色交替闪来闪去，可不可以放上了的就不渲染，拆掉再继续渲染呢」

    现象的解释: 我们按投影的坐标把实物放下去之后，**实物和投影的蓝色网格
    几乎完全重合** ⇒ 两个面在同一个深度上互相争夺（z-fighting）⇒ 肉眼看到
    的就是"彩色 / 蓝色交替闪"。不重合的时候反而不闪。

    做法（两条互补）:
      ① **重灌时扫一遍**（`Placed.refresh`）: 用 `Snap.gather` 拿到投影范围内的
         **真实建筑**（位置 + 类型），对每一条投影记录问一句"同类型、附近
         有没有实物" ⇒ 有就把这条记录**排除渲染**（写进 `Ghost.skip`）。
         这一步同时覆盖了"拆掉恢复"（拆了就没有实物了 ⇒ 不再排除）。
      ② **放下瞬间立刻隐藏**（`Placed.note_new_object`）: UE4SS 的
         `NotifyOnNewObject` 会在新建筑出现时通知我们，拿着这个 actor 的
         位置/类型直接匹配到记录 ⇒ 立刻标记隐藏并重灌一次。
         不用等下一次全扫（全扫要读几千个 actor，会卡一下）。

    拆掉之后怎么恢复: ② 里我们**记着那个 actor 的引用**，每隔几秒检查一次
    "它还活着吗"（`Util.valid`）；发现它没了 ⇒ 认为被拆了 ⇒ 解除隐藏并重灌。
    （世界切换时 main 会调 `Placed.forget()` 丢掉这些引用，绝不跨世界持有。）

    安全约定（和规矩 3b 一致）: 全程 pcall；任何一步失败都只是"没隐藏/没恢复"，
    绝不影响放置本身。

    配置: `ghost_hide_placed`（默认 true）、`ghost_hide_placed_cm`（默认 100）。
]]

local Util = require("pwpr_util")
local Log = require("pwpr_log")

local Placed = {}

Placed.hidden = {}        -- [记录序号] = true —— 这一条不再渲染
Placed.refs = {}          -- [记录序号] = actor —— 用来判断"拆掉了没有"
Placed.pending = {}       -- [记录序号] = true —— 已放上、**等批量窗口结束**再一起隐藏
Placed.pending_actor = {} -- [记录序号] = actor（批量窗口结束时一起并进 refs）
Placed.last_n = 0         -- 上一次隐藏了几件
Placed.last_src = nil     -- 上一次的数据来源（日志/状态里显示）
Placed.max_records = 4000 -- 保险: 记录特别多时不全扫（避免长时间卡顿）

local function cfg_get(key)
    local ok, v = pcall(function()
        return require("pwpr_config").get(key)
    end)
    if ok then return v end
    return nil
end

--- 一条记录在当前投影下的世界坐标（与 pwrp_buildsnap / pwpr_snap 同一公式）
local function record_world(place, b)
    if type(b) ~= "table" or type(b.p) ~= "table" then return nil end
    local rx = (tonumber(b.p[1]) or 0.0) * 100.0
    local ry = (tonumber(b.p[2]) or 0.0) * 100.0
    local rz = (tonumber(b.p[3]) or 0.0) * 100.0
    local rad = math.rad(place.yaw or 0.0)
    local c, s = math.cos(rad), math.sin(rad)
    return place.x + (rx * c - ry * s), place.y + (rx * s + ry * c), place.z + rz
end

--- 清空（收起投影 / 换蓝图 / 换世界时调用）
function Placed.forget()
    Placed.hidden = {}
    Placed.refs = {}
    Placed.pending = {}
    Placed.pending_actor = {}
    Placed.last_n = 0
end

--- ★ **精确隐藏一条记录**（吸附那边告诉我们"我正要往这一条放"）。
---
--- 为什么这条最重要（2026-09-29 实测）: 它是**唯一不需要猜**的路径 ——
---   投影侧知道玩家瞄准的是哪一条记录，所以"放一块 = 藏一条"，不会误伤旁边。
---   而全扫那条路是"按坐标猜"，只能作为兜底（拆掉恢复、别人放的东西等）。
---
--- ★ 2026-09-29 玩家提的方案（已实现）: **入队，不立刻隐藏**。
---   连放时只记录（零开销），停下来（默认 3 秒没有新放置）再**一次性**隐藏。
---   好处: ① 连放 20 块只重灌一次；② 每条记录只入队一次，放再快也不会漏。
function Placed.hide_now(rec_idx)
    if rec_idx == nil then return false end
    if Placed.hidden[rec_idx] == true then return false end
    if Placed.pending[rec_idx] == true then return false end
    Placed.pending[rec_idx] = true
    -- ★ 记下"最后一次入队的时间" —— 队列表用它判断"安静够久了没有"
    --   （批量清算除了定时回调，还有一条兜底路径看这个值，见 main 的 watch tick）
    Placed.pending_since = os.clock()
    Placed.last_pending_n = Placed.pending_count()
    return true
end

--- 待处理队列"安静"了多少秒（没有待处理就返回 0）
function Placed.pending_idle_s()
    if Placed.pending_since == nil then return 0.0 end
    if Placed.pending_count() == 0 then return 0.0 end
    return os.clock() - Placed.pending_since
end

--- 等批量窗口结束时调用: 把"待隐藏"的挪进"隐藏"名单，返回这次的记录序号表。
--- 没有待处理的就返回空表。
function Placed.take_pending()
    local list = {}
    for idx in pairs(Placed.pending) do
        list[#list + 1] = idx
        Placed.hidden[idx] = true
        local actor = Placed.pending_actor[idx]
        if actor ~= nil then Placed.refs[idx] = actor end
    end
    Placed.pending = {}
    Placed.pending_actor = {}
    Placed.pending_since = nil
    Placed.last_n = Placed.count()
    return list
end

--- 撤销"待隐藏"（游戏拒绝了这次放置时用）。返回 true 表示确实取消了
function Placed.cancel_pending(rec_idx)
    if rec_idx == nil or Placed.pending[rec_idx] ~= true then return false end
    Placed.pending[rec_idx] = nil
    Placed.pending_actor[rec_idx] = nil
    if Placed.pending_count() == 0 then Placed.pending_since = nil end
    Placed.last_pending_n = Placed.pending_count()
    return true
end

--- 待处理条数（状态行/日志用）
function Placed.pending_count()
    local n = 0
    for _ in pairs(Placed.pending) do n = n + 1 end
    return n
end

--- 落地确认成功: 记下这个 actor（"拆掉检测"要用）。
--- 注意: 这时那一件可能还在"待隐藏"队列里 ⇒ 先放 pending_actor，批量结束时并进 refs。
function Placed.stash_actor(rec_idx, actor)
    if rec_idx == nil or actor == nil then return end
    if Placed.hidden[rec_idx] == true then
        Placed.refs[rec_idx] = actor
    else
        Placed.pending_actor[rec_idx] = actor
    end
end

--- 落地确认成功（旧名字，保留兼容）: 记下这个 actor
function Placed.confirm_hidden(rec_idx, actor)
    Placed.stash_actor(rec_idx, actor)
end

--- 撤销隐藏（游戏没建出来时用）。返回 true 表示确实撤销了
function Placed.unhide(rec_idx)
    if rec_idx == nil then return false end
    local did = false
    if Placed.pending[rec_idx] == true then
        Placed.pending[rec_idx] = nil
        Placed.pending_actor[rec_idx] = nil
        Placed.last_pending_n = Placed.pending_count()
        did = true
    end
    if Placed.hidden[rec_idx] == true then
        Placed.hidden[rec_idx] = nil
        Placed.refs[rec_idx] = nil
        Placed.last_n = Placed.count()
        did = true
    end
    return did
end

--- 记录集是否为空（给状态行用）
function Placed.count()
    local n = 0
    for _ in pairs(Placed.hidden) do n = n + 1 end
    return n
end

--- ★ 全扫一遍: 把"已经放上了"的记录标出来。
--- 返回 隐藏件数, 说明（失败时返回 nil, 原因）
function Placed.refresh(bp, place)
    -- ★★ 自保: 这条路径要**枚举关卡建筑**，而 `level.Actors` 会保留已摧毁的
    --   actor（读它 = 原生访问违例，见 pwpr_config.lua 的 ghost_hide_enum）。
    --   默认关闭；只有显式打开才允许跑。
    if cfg_get("ghost_hide_enum") ~= true then
        return nil, "枚举已关闭（ghost_hide_enum = false）"
    end
    if cfg_get("ghost_hide_placed") ~= true then
        Placed.hidden = {}
        Placed.refs = {}
        Placed.last_src = "功能已关闭"
        return 0, "功能已关闭"
    end
    if type(bp) ~= "table" or type(bp.buildings) ~= "table" or place == nil then
        return nil, "没有蓝图/投影位置"
    end
    -- ★ 把"待批量处理"的先并进 hidden —— 这样在批量窗口结束前按 K / 换层，
    --   已经放上的那些也不会被这次全扫"忘掉"。
    for idx in pairs(Placed.pending) do
        Placed.hidden[idx] = true
        local actor = Placed.pending_actor[idx]
        if actor ~= nil then Placed.refs[idx] = actor end
    end
    Placed.pending = {}
    Placed.pending_actor = {}

    local n_rec = #bp.buildings
    if n_rec > Placed.max_records then
        Placed.hidden = {}
        Placed.last_src = string.format("记录太多（%d > %d），跳过", n_rec,
            Placed.max_records)
        return nil, Placed.last_src
    end

    local Snap = nil
    local okr = pcall(function() Snap = require("pwpr_snap") end)
    if not okr or Snap == nil or Snap.gather == nil then
        return nil, "拿不到 pwpr_snap（不做隐藏）"
    end

    -- 收集范围: 投影记录到原点最远有多远 + 判定半径 ⇒ 范围内没有遗漏
    local reach = 0.0
    for i = 1, n_rec do
        local b = bp.buildings[i]
        if type(b) == "table" and type(b.p) == "table" then
            local d = math.sqrt((tonumber(b.p[1]) or 0.0) ^ 2
                + (tonumber(b.p[2]) or 0.0) ^ 2
                + (tonumber(b.p[3]) or 0.0) ^ 2)
            if d > reach then reach = d end
        end
    end
    local near_cm = tonumber(cfg_get("ghost_hide_placed_cm")) or 40.0
    local radius_cm = reach * 100.0 + near_cm

    local anchors, src = Snap.gather(place.x, place.y, place.z, radius_cm)
    if anchors == nil then
        return nil, "扫真实建筑失败: " .. tostring(src)
    end
    -- 剩下的匹配/点名逻辑和"分片全扫"共用（见 apply_anchors）
    return Placed.apply_anchors(bp, place, anchors)
end

--- ★★ **分片全扫**（2026-09-29 加的，为修"每次刷新都卡一下"）
---
--- 为什么: 兜底全扫原来一次读完**整个关卡**的建筑列表（实测 600+ 个 actor，
---   每个还要读位置/类型/朝向 —— 全是跨 Lua/引擎边界的调用），
---   这一趟集中在**同一帧**里 ⇒ 玩家看到的就是"每隔几秒卡一下"。
---   （以前没被发现，是因为这个全扫**从来没跑起来过**，见 §59。）
---
--- 现在拆成两块优化:
---   ① **只关心"已隐藏的那几条记录的类型"** —— 类型对不上的 actor
---      连位置都不用读（省掉一半以上的反射调用）；
---   ② **每个 tick 只读一小片**（默认 150 个）⇒ 一趟扫完约 4~5 个 tick
---      （约 10 秒），但**任何一帧的开销都很小**，不再有可见的卡顿。
---
--- 返回: nil, "progress"（还没扫完） / 记录序号表（扫完了，可能为空表）
function Placed.scan_step(max_n)
    local deps = Placed.deps
    if deps == nil or deps.context == nil then return nil, "没有 context" end
    local ok, bp, place = pcall(deps.context)
    if not ok or bp == nil or place == nil then
        Placed.scan = nil
        return nil, "没有投影"
    end

    -- 没在扫就开一趟（**只在确实藏了东西时才扫** —— 没藏东西时完全零开销）
    -- ★★ 自保（两道）: 周期性扫描要**两个开关都开**才允许跑 ——
    --   `ghost_hide_enum`（允许枚举）+ `ghost_hide_scan`（允许周期性扫描）。
    --   后者是两次崩溃的路线（拆完建筑后读到 pending-kill 对象），默认关。
    if cfg_get("ghost_hide_enum") ~= true
        or cfg_get("ghost_hide_scan") ~= true then
        Placed.scan = nil
        return {}, "周期性扫描已关闭"
    end

    local s = Placed.scan
    if s == nil then
        if Placed.count() == 0 then return {}, "nothing-hidden" end
        local types = {}
        for idx in pairs(Placed.hidden) do
            local b = bp.buildings[idx]
            if type(b) == "table" then types[Util.norm_id(b.t)] = true end
        end
        if next(types) == nil then return {}, "no-types" end
        local Capture = nil
        pcall(function() Capture = require("pwpr_capture") end)
        if Capture == nil or Capture.list_build_actors == nil then
            return nil, "拿不到建筑列表"
        end
        local objs, src = Capture.list_build_actors()
        if objs == nil then return nil, "列不出建筑: " .. tostring(src) end
        s = { objs = objs, cursor = 1, types = types, anchors = {} }
        Placed.scan = s
    end

    -- 这一片: 读 150 个 actor（类型不关心就只读类型）
    local upto = math.min(#s.objs, s.cursor + (max_n or 150) - 1)
    for i = s.cursor, upto do
        local obj = s.objs[i]
        local t = nil
        pcall(function() t = Util.type_of(obj) end)
        local k = (t ~= nil) and Util.norm_id(t) or ""
        if k ~= "" and s.types[k] == true then
            local x, y, z = Util.loc_of(obj)
            if x ~= nil then
                s.anchors[#s.anchors + 1] = { x = x, y = y, z = z, t = t, obj = obj }
            end
        end
    end
    s.cursor = upto + 1
    if s.cursor <= #s.objs then
        return nil, string.format("progress %d/%d", upto, #s.objs)
    end

    -- 读完了 ⇒ 用这批参照重算名单（和完整 refresh 用同一套匹配）
    local anchors = s.anchors
    local n_objs = #s.objs
    Placed.scan = nil
    -- ★ 注意: apply_anchors 的第一个返回值是"隐藏件数（数字）"，
    --   而这里要返回的是"变了哪几条"（表）—— 用 last_delta，别搞混。
    pcall(Placed.apply_anchors, bp, place, anchors)
    local delta = Placed.last_delta or {}
    Placed.last_src = string.format("分片全扫: %d/%d 个参照, 隐藏 %d 件",
        #anchors, n_objs, Placed.count())
    return delta, "done"
end

--- 用一批"真实建筑参照"重算隐藏名单。返回"变化了的记录序号表"。
--- （完整全扫 `refresh` 与分片全扫 `scan_step` 共用这一段）
function Placed.apply_anchors(bp, place, anchors)
    local near_cm = tonumber(cfg_get("ghost_hide_placed_cm")) or 40.0
    local near2 = near_cm * near_cm
    local n_rec = #bp.buildings

    -- 按类型分组（同一类型内找最近的实物，几百个参照也只扫一遍）
    local by_type = {}
    for i = 1, #anchors do
        local a = anchors[i]
        local k = Util.norm_id(a.t)
        if k ~= "" then
            local l = by_type[k]
            if l == nil then l = {}; by_type[k] = l end
            l[#l + 1] = a
        end
    end

    -- 上一轮的名单（用来算"这一轮变了哪几条"）
    local prev_hidden = Placed.hidden
    local hidden, n = {}, 0
    local fresh_refs = {}

    -- ★★ 一对一指派（2026-09-29 玩家实测: "除了放置的那块，还会把边上某块
    --    也一起取消投影"）。
    --   老写法是"每条记录各自找最近的实物"⇒ **一个实物可以认领多条记录**
    --   （只要它们都在 near_cm 内）⇒ 放一块地板会把旁边那条记录也藏掉。
    --   ⇒ 现在改成: 先把所有 (记录, 实物, 距离) 配对按距离排序，
    --     然后**贪心认领 —— 一个实物只能认领一条记录**（最近的先认）。
    --     这样"放一块 = 藏一条"，跟玩家的直觉一致。
    local pairs_all = {}
    for i = 1, n_rec do
        local b = bp.buildings[i]
        if type(b) == "table" then
            local list = by_type[Util.norm_id(b.t)]
            if list ~= nil then
                local wx, wy, wz = record_world(place, b)
                if wx ~= nil then
                    for j = 1, #list do
                        local a = list[j]
                        local dx, dy, dz = a.x - wx, a.y - wy, a.z - wz
                        local d2 = dx * dx + dy * dy + dz * dz
                        if d2 <= near2 then
                            pairs_all[#pairs_all + 1] = { i = i, a = a, d2 = d2 }
                        end
                    end
                end
            end
        end
    end
    table.sort(pairs_all, function(p, q) return p.d2 < q.d2 end)
    local claimed = {}
    local shown = {}
    for k = 1, #pairs_all do
        local pr = pairs_all[k]
        if hidden[pr.i] ~= true and claimed[pr.a] ~= true then
            claimed[pr.a] = true
            hidden[pr.i] = true
            n = n + 1
            -- ★ 记下这个实物 actor: 每 2.5 秒用它判断"拆了没有"
            if pr.a.obj ~= nil then fresh_refs[pr.i] = pr.a.obj end
            if #shown < 6 then
                shown[#shown + 1] = string.format("#%d(%.0f厘米)", pr.i,
                    math.sqrt(pr.d2))
            end
        end
    end
    Placed.last_hidden_note = (#shown > 0)
        and ("刚藏掉: " .. table.concat(shown, " ")) or nil

    -- ★★ refs 只用**这一轮刚从活对象里扫出来的**（fresh_refs）。
    --
    -- 2026-09-29 崩溃教训: 原来这里还会 `Util.valid(旧 actor)` 去"续用上一轮的引用"
    --   —— 而那些引用可能指向**已被摧毁的 actor**，对它们调引擎函数就是
    --   原生访问违例（pcall 抓不住）。既然每次全扫都能从**活对象**里重新拿到句柄，
    --   就完全没必要留着旧的（宁可丢句柄，也不能摸尸体）。
    local keep_refs = {}
    for idx, actor in pairs(fresh_refs) do keep_refs[idx] = actor end
    Placed.hidden = hidden
    Placed.refs = keep_refs
    -- ★ 把"这一轮**变化**了哪几条"算出来 —— 调用方据此只重灌受影响的组
    --   （不重灌整个投影；见 Ghost.rehide）。增/删都算变化。
    local delta = {}
    for i in pairs(hidden) do
        if prev_hidden[i] ~= true then delta[#delta + 1] = i end
    end
    for i in pairs(prev_hidden) do
        if hidden[i] ~= true then delta[#delta + 1] = i end
    end
    Placed.last_delta = delta
    Placed.last_n = n
    Placed.last_src = string.format("全扫: %d 件参照, 隐藏 %d/%d",
        #anchors, n, n_rec)
    return n, Placed.last_src
end

--- ★ 新建筑出现时**只做记录**，不再拿它去匹配（2026-09-29 实测教训）。
---
--- 为什么把"直接匹配"删掉:
---   `NotifyOnNewObject` 触发得**太早**，那一刻新 actor 的位置/类型还没填好
---   （一次会话里 80 次改发 / 33 次确认建出，而这条快路径 **0 次命中**；
---   更糟的是它偶尔会读到一个**不可靠的位置**，于是把**旁边那条记录**也藏了 ——
---   玩家实测:「除了放置的那块，还会把他边上的某块也一起取消投影，
---   在下一次放置的时候又给他补回去」（下一次全扫是可靠的 ⇒ 自动纠正）。
---   ⇒ 结论: **只留可靠的那条路**（收到通知 → 排一次重灌 → 里面的全扫），
---     这条只把读到的值写进日志，供以后排查。
--- 返回: 永远 nil（调用方不要再据此决定"要不要重灌"）
function Placed.note_new_object(obj)
    if obj == nil then return nil end
    local Snap = nil
    pcall(function() Snap = require("pwpr_snap") end)
    if Snap == nil then return nil end
    local a = nil
    pcall(function() a = Snap.read_anchor(obj) end)
    if a == nil then
        Placed.last_read = "通知时读不到位置/类型（太早）"
    else
        Placed.last_read = string.format("%s @ (%.0f,%.0f,%.0f)",
            tostring(a.t), a.x, a.y, a.z)
    end
    Log.line("  [placed] 新建筑通知（只记录，不据此隐藏）: " ..
        tostring(Placed.last_read))
    return nil
end

--- ★ 轻量检查: 我们隐藏的那些实物还在不在（拆掉 ⇒ 解除隐藏）。
--- 返回 true 表示"有变化，应该重灌一次"（调用方负责重灌）
---
--- ⚠️ 2026-09-29 玩家实测: 这条**有时不灵**（"拆除后没效果，只能按两次 K"）——
---   游戏的拆除不一定会让 `Util.valid` 立刻变 false（可能先播动画/延迟销毁，
---   也可能对象被回收后 IsValid 仍然撒谎）。
---   ⇒ 所以调用方现在还会**每隔几秒做一次全扫**（成本很低: 实测这个基地只读
---     677 个 actor），全扫的结果才是权威的。这里保留快路径只是为了
---     "拆了以后 2.5 秒内就恢复"这种更好的手感。
function Placed.check_alive()
    -- ★★ 自保: 这条路径默认是**关**的（`ghost_hide_alive_check`）——
    --   它会对可能已摧毁的 actor 调引擎函数，而原生崩溃 pcall 抓不住。
    --   这里再拦一道，防止以后有别的调用方误用它。
    if cfg_get("ghost_hide_alive_check") ~= true then return nil end
    -- ★ 没有句柄 = 快路径**查不了**（2026-09-29 实测踩过: 那些件只能等十几秒的
    --   兜底全扫，玩家体感就是"拆掉恢复不触发了"）。这里明确写出来，
    --   免得下次又要从"没反应"倒推。
    if next(Placed.refs) == nil then
        if Placed.count() > 0 then
            Log.line(string.format(
                "  [placed] 拆掉检查: **0 个句柄**（藏了 %d 件，但这些件没记到 actor "
                .. "⇒ 只能等兜底全扫；看上面的入队/批量隐藏日志找原因）",
                Placed.count()))
        end
        return nil
    end
    local changed = {}
    local checked, alive_n = 0, 0
    for idx, actor in pairs(Placed.refs) do
        local alive = false
        pcall(function() alive = Util.valid(actor) end)
        checked = checked + 1
        if alive then
            alive_n = alive_n + 1
        else
            Placed.refs[idx] = nil
            if Placed.hidden[idx] == true then
                Placed.hidden[idx] = nil
                changed[#changed + 1] = idx
                Log.emit(string.format(
                    "  [placed] 记录 #%d 的实物没了（拆掉/被摧毁）⇒ 恢复渲染它", idx))
            end
        end
    end
    -- ★ 把"检查了几个、几个还活着"写进日志 —— 下次就能看出这条快路径到底灵不灵
    --   （如果一直显示"全部存活"而玩家明明拆了，那就是 IsValid 在撒谎）。
    Log.line(string.format("  [placed] 拆掉检查: %d 个引用，%d 个存活",
        checked, alive_n))
    if #changed > 0 then
        local Ghost = nil
        pcall(function() Ghost = require("pwpr_ghost") end)
        if Ghost ~= nil then Ghost.skip = Placed.hidden end
        Placed.last_n = Placed.count()
    end
    return changed
end

--- ★ 定时全扫: 返回**变化了的记录序号表**（没变就是空表）。
--- 调用方拿着这个表去 `Ghost.rehide(表)` ⇒ 只重灌受影响的组，不重灌整个投影。
function Placed.refresh_delta()
    local deps = Placed.deps
    if deps == nil or deps.context == nil then return nil end
    local ok, bp, place = pcall(deps.context)
    if not ok or bp == nil or place == nil then return nil end
    local n_ok = pcall(Placed.refresh, bp, place)
    if not n_ok then return nil end
    local delta = Placed.last_delta or {}
    if #delta > 0 then
        Log.emit(string.format(
            "  [placed] 定时全扫: 名单变了 %d 条（现在共隐藏 %d 件）",
            #delta, Placed.count()))
    else
        Log.line("  [placed] 定时全扫: 名单没变（隐藏 "
            .. tostring(Placed.count()) .. " 件）")
    end
    return delta
end

--- 隐藏名单的"指纹"（只用来比较变没变）
function Placed.signature()
    local keys = {}
    for i in pairs(Placed.hidden) do keys[#keys + 1] = i end
    table.sort(keys)
    return table.concat(keys, ",")
end

--- 给状态行（F7）用的一句话
function Placed.status_line()
    if cfg_get("ghost_hide_placed") ~= true then
        return "已放上的不渲染: 关（ghost_hide_placed = false）"
    end
    local extra = ""
    if Placed.last_read ~= nil then
        extra = "；最近一次新建筑通知读到: " .. tostring(Placed.last_read)
    end
    if cfg_get("ghost_hide_scan") ~= true then
        return string.format(
            "已放上的不渲染: 开（精确隐藏 %d 件，待处理 %d；按 K 会扫一遍标出"
            .. "已放过的件）；**自动发现拆除: 关**（ghost_hide_scan=false，防崩）"
            .. "—— 拆掉的件按 K 收起再放一次就会重新画出来",
            Placed.count(), Placed.pending_count())
    end
    return string.format("已放上的不渲染: 开（隐藏 %d 件，待处理 %d，%d 个可追踪；%s%s）",
        Placed.count(), Placed.pending_count(), (function()
            local n = 0
            for _ in pairs(Placed.refs) do n = n + 1 end
            return n
        end)(), tostring(Placed.last_src or "还没扫过"), extra)
end

return Placed
