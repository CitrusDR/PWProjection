--[[ ===========================================================================
  PWPR · snap  ——  建筑吸附：把投影一步对齐到"原建筑"的实际位置

  ============================================================================
  它解决什么（对应 docs/项目状态与路线图.md 的"待办 2"）
  ============================================================================
  投影刚放出来时，原点在"玩家脚下"、朝向是 0 —— 和原基地的实际位置差着一截。
  用小键盘一格一格挪一栋大建筑要按几十下，而且很难看出"到底差多少"。
  吸附做的事: **在附近找同类型的真实建筑，用它们反推投影该在哪** ——
  一次按键把偏移（必要时连朝向）算出来，不改蓝图数据、只改投影偏移。

  ============================================================================
  算法（只用 位置 / 类名 / actor 朝向，**不碰网格资产**）
  ============================================================================
   1. 收集参照建筑: 读"本关卡活着的 PalBuildObject"的位置/类名/朝向。
      ★ 故意不读网格组件 —— 老存档里"游戏更新后已删除"的网格资产是野指针，
        碰它就是访问违例（见 docs/踩坑记录.md §29）。位置+类型已经够配对用了。
   2. 配对: 为每条蓝图记录找【最近的同类参照】（阈值 snap_radius_cm）。
   3. 朝向投票: 每一对给出"要让这件对上，投影得转多少度" =
      参照朝向 - 记录朝向。票数最高的几个当候选，**外加"当前朝向"**
      （并列时优先"不动"）。
   4. 偏移投票: 每一对给出一个"投影原点应该在哪"的三维候选点，
      按 25 厘米分格投票 → 票数最高的格 + 格内平均。
   5. 复核: 对（朝向候选 × 偏移候选）逐个算"有多少条记录能与同类参照对上"
      （阈值 snap_verify_cm），取复核分最高的那个。
   6. 至少要对上 snap_min_matches 件才接受；否则**不动投影**，只报告原因。

  ★ 为什么"复核分"是胜负手:
    基地里大量结构件是**格状排列**的 ⇒ "错一格"的对齐同样能对上很多件
    （格状对称，票数也一样高）。真对齐的特征不是"结构件对得多"，
    而是**连稀有件（机器/设施）也对上** —— 复核是拿【全部】记录算的，
    稀有的那几件正是分胜负的地方。

  ============================================================================
  坐标约定（和 pwpr_ghost 完全一致）
  ============================================================================
     一条记录的世界位置 = place + R(place.yaw) · rel_cm
     所以"要让第 k 件落在参照 a 上"  ⇒  place = a - R(yaw) · rel_cm[k]
     place 换算回 Session 的偏移只需要一个增量:
         offset = offset + (place_new - place_old)      ← 不需要知道脚底/半高
=========================================================================== ]]

local Util = require("pwpr_util")
local BP = require("pwpr_bp")
local Capture = require("pwpr_capture")
local Log = require("pwpr_log")

local Snap = {}

-- --------------------------------------------------------------------------
-- 常量（内部参数，改这些不用动配置）
-- --------------------------------------------------------------------------

Snap.MAX_ANCHORS = 4000       -- 参照建筑最多用多少个（超了按距离取最近的）
Snap.VOTE_CELL_CM = 25.0      -- 偏移投票的分格（厘米）
Snap.YAW_BUCKET = 5.0         -- 朝向投票的分格（度）
Snap.YAW_TOL = 10.0           -- 两个朝向候选"算同一个"的容差（度）
Snap.MAX_YAW_CAND = 3         -- 最多试几个朝向候选
Snap.MAX_OFFSET_PEAK = 2      -- 最多试几个偏移候选（次高峰也算，见"复核分"注释）
Snap.WORK_BUDGET = 1500000    -- 距离比较次数的上限（超了就对记录抽样）
Snap.SEED_MAX = 30            -- 用"最可信的几对"生成几个候选偏移
Snap.SCORE_SAMPLES = 120      -- 候选打分用的记录样本数（粗筛，快）
Snap.FINAL_VERIFY = 3         -- 粗筛前几名才做"全部记录"的完整复核（贵）
Snap.DEDUP_CM = 50.0          -- 两个候选挨得比这还近就算同一个

-- --------------------------------------------------------------------------
-- 小工具
-- --------------------------------------------------------------------------

--- 平方距离（厘米²）
local function dist2(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

--- 在 list 里找离 (x,y,z) 最近的一个（只在 r2 以内找）。
--- 返回 元素, 距离（厘米）；没找到返回 nil
local function nearest(x, y, z, list, r2)
    local best, bestd = nil, r2
    for i = 1, #list do
        local a = list[i]
        local dx, dy, dz = a.x - x, a.y - y, a.z - z
        local d = dx * dx + dy * dy + dz * dz
        if d <= bestd then
            bestd, best = d, a
        end
    end
    if best == nil then return nil end
    return best, math.sqrt(bestd)
end

--- 水平距离（用于"取最近的 N 个参照"时的排序；建筑都是站在地面上的）
local function horiz2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

-- --------------------------------------------------------------------------
-- 1. 收集参照建筑
-- --------------------------------------------------------------------------

--- 读一个参照建筑。只用三个**已经在采集流程里长期验证过**的调用。
--- 返回 { x=,y=,z=, t=, yaw= } 或 nil
function Snap.read_anchor(obj)
    local x, y, z = Util.loc_of(obj)
    if x == nil then return nil end
    local t = Util.type_of(obj)          -- 第一个返回值 = 短类型名
    if t == nil then return nil end
    local _, yaw, _ = Util.rot_of(obj)
    -- ★ `obj` 也带出去（2026-09-29）: 投影侧要拿它当"这一件还在不在"的句柄 ——
    --   被拆掉时那个 actor 会被销毁，靠 `Util.valid(obj)` 就能发现 ⇒ 恢复渲染。
    --   以前只返回坐标/类型，于是"已经放上的不渲染"只能靠重新全扫才知道被拆了。
    return { x = x, y = y, z = z, t = t, yaw = yaw or 0.0, obj = obj }
end

--- 收集以 (cx,cy,cz) 为中心、radius_cm 内的参照建筑。
--- 返回 list, info(表) 或 nil, 原因
function Snap.gather(cx, cy, cz, radius_cm)
    local objs, src = Capture.list_build_actors()
    if objs == nil then
        return nil, "拿不到本关卡的建筑列表: " .. tostring(src)
    end
    local r2 = radius_cm * radius_cm
    local list = {}
    -- ★ 进度点（只进文件，每 250 个刷一次盘）: 这一趟要读几千个 actor，
    --   万一崩了，日志最后一行就能指出"读到第几个崩的"。
    for i = 1, #objs do
        local a = Snap.read_anchor(objs[i])
        if a ~= nil then
            if dist2(a.x, a.y, a.z, cx, cy, cz) <= r2 then
                list[#list + 1] = a
            end
        end
        if (i % 250) == 0 then
            Log.line(string.format("  [snap] 读参照 %d/%d（命中 %d）", i, #objs, #list))
            Log.flush()
        end
    end
    local info = {
        level_total = #objs,
        in_range = #list,
        source = src,
        radius_cm = radius_cm,
    }
    if #list > Snap.MAX_ANCHORS then
        -- 太多了: 按到中心的水平距离取最近的若干个（比"随便砍"合理）
        for i = 1, #list do
            list[i]._h2 = horiz2(list[i].x, list[i].y, cx, cy)
        end
        table.sort(list, function(p, q) return p._h2 < q._h2 end)
        local kept = {}
        for i = 1, Snap.MAX_ANCHORS do kept[i] = list[i] end
        info.truncated = #list - Snap.MAX_ANCHORS
        list = kept
    end
    return list, info
end

-- --------------------------------------------------------------------------
-- 2. 归档 + 配对
-- --------------------------------------------------------------------------

--- 把参照按类型归档: t -> { {x,y,z,yaw}, ... }
local function index_anchors(list)
    local out = {}
    for i = 1, #list do
        local a = list[i]
        local bucket = out[a.t]
        if bucket == nil then
            bucket = {}
            out[a.t] = bucket
        end
        bucket[#bucket + 1] = a
    end
    return out
end

--- 把蓝图记录按类型归档: t -> { {x,y,z,yaw}, ... }（x/y/z = 相对包围盒中心的厘米）
local function index_records(bp)
    local out, total = {}, 0
    local bs = (bp ~= nil) and bp.buildings or {}
    for i = 1, #bs do
        local b = bs[i]
        if type(b) == "table" and type(b.t) == "string" then
            local rx, ry, rz = BP.rel_cm(b)
            if rx ~= nil then
                local bucket = out[b.t]
                if bucket == nil then
                    bucket = {}
                    out[b.t] = bucket
                end
                bucket[#bucket + 1] = {
                    x = rx, y = ry, z = rz,
                    yaw = tonumber(b.yaw) or 0.0,
                }
                total = total + 1
            end
        end
    end
    return out, total
end

--- 规划抽样步长: 返回 { t -> stride } 与"预计比较次数"。
---
--- ★ 为什么允许抽样: 配对只需要"够投票"的样本量（几百对），
---   而一个上万件的基地逐件比一遍纯属浪费（按键会卡住）。
---   稀有的类型（机器/设施）永远不抽样 —— 它们正是分胜负的证据。
local function plan_stride(recs, ancs)
    local types = {}
    local total = 0
    for t, rl in pairs(recs) do
        local al = ancs[t]
        if al ~= nil then
            types[#types + 1] = { t = t, nr = #rl, na = #al }
            total = total + #rl * #al
        end
    end
    local stride = {}
    if total <= Snap.WORK_BUDGET or #types == 0 then
        for i = 1, #types do stride[types[i].t] = 1 end
        return stride, total, types
    end
    -- 超预算: 按"每种类型分同样多的预算"来定步长（大类型抽稀，小类型不动）
    local per_type = math.max(math.floor(Snap.WORK_BUDGET / #types), 1)
    local est = 0
    for i = 1, #types do
        local e = types[i]
        local work = e.nr * e.na
        local s = 1
        if work > per_type then
            s = math.ceil(work / per_type)
            if s > e.nr then s = e.nr end
        end
        stride[e.t] = s
        est = est + math.ceil(e.nr / s) * e.na
    end
    return stride, est, types
end

--- 在 (place, yaw) 下，为每条记录找最近的同类参照。
--- 返回配对表（每条 = { r=记录, a=参照, d=距离厘米 }）
---
--- ★ 局部变量**不能叫 pairs** —— 那会遮蔽 Lua 的全局 `pairs()`，
---   同一个作用域里再用 `pairs(t)` 就变成"调用一张表"（必崩），
---   而且静态检查器也不允许（见 tools/luacheck.py 第 8 项）。
local function match_pairs(recs, ancs, place, yaw, radius_cm, stride)
    local rad = math.rad(yaw)
    local c, s = math.cos(rad), math.sin(rad)
    local r2 = radius_cm * radius_cm
    local out = {}
    for t, rl in pairs(recs) do
        local al = ancs[t]
        if al ~= nil then
            local st = stride[t] or 1
            for i = 1, #rl, st do
                local r = rl[i]
                -- 这一件现在在哪（世界厘米）
                local wx = place.x + (r.x * c - r.y * s)
                local wy = place.y + (r.x * s + r.y * c)
                local wz = place.z + r.z
                local a, d = nearest(wx, wy, wz, al, r2)
                if a ~= nil then
                    out[#out + 1] = { r = r, a = a, d = d }
                end
            end
        end
    end
    return out
end

-- --------------------------------------------------------------------------
-- 3. 朝向投票
-- --------------------------------------------------------------------------

--- 候选朝向列表（第一个永远是"当前朝向"）
local function yaw_candidates(matched, yaw_now, search)
    local buckets = {}
    for i = 1, #matched do
        local p = matched[i]
        local y = Util.norm_yaw((p.a.yaw or 0.0) - (p.r.yaw or 0.0))
        -- ★ 分格前先平移到 0..360: 这样"±180 附近"的值会落在同一个格里，
        --   格内平均就不会被回绕拆开。
        local key = math.floor((y + 180.0) / Snap.YAW_BUCKET)
        local b = buckets[key]
        if b == nil then
            b = { n = 0, sum = 0.0, key = key }
            buckets[key] = b
        end
        b.n = b.n + 1
        b.sum = b.sum + y
    end
    local list = {}
    for _, b in pairs(buckets) do
        b.avg = Util.norm_yaw(b.sum / b.n)
        list[#list + 1] = b
    end
    table.sort(list, function(p, q)
        if p.n == q.n then return p.key < q.key end
        return p.n > q.n
    end)

    local out = { yaw_now }
    if search then
        for i = 1, #list do
            if #out >= Snap.MAX_YAW_CAND then break end
            local cand = list[i].avg
            local dup = false
            for j = 1, #out do
                if math.abs(Util.norm_yaw(cand - out[j])) < Snap.YAW_TOL then
                    dup = true
                    break
                end
            end
            if not dup then out[#out + 1] = cand end
        end
    end
    return out, list
end

-- --------------------------------------------------------------------------
-- 4. 偏移投票
-- --------------------------------------------------------------------------

--- 由配对反推"投影原点该在哪"。返回 peaks（按票数降序，最多 MAX_OFFSET_PEAK 个）
local function offset_peaks(matched, yaw, want)
    local rad = math.rad(yaw)
    local c, s = math.cos(rad), math.sin(rad)
    local cell = Snap.VOTE_CELL_CM
    local votes = {}
    for i = 1, #matched do
        local p = matched[i]
        -- 让这一件落在参照上 ⇒ place = a - R(yaw)·rel
        local px = p.a.x - (p.r.x * c - p.r.y * s)
        local py = p.a.y - (p.r.x * s + p.r.y * c)
        local pz = p.a.z - p.r.z
        local key = string.format("%d,%d,%d",
            math.floor(px / cell), math.floor(py / cell), math.floor(pz / cell))
        local v = votes[key]
        if v == nil then
            v = { n = 0, sx = 0.0, sy = 0.0, sz = 0.0 }
            votes[key] = v
        end
        v.n = v.n + 1
        v.sx, v.sy, v.sz = v.sx + px, v.sy + py, v.sz + pz
    end

    local all = {}
    for _, v in pairs(votes) do
        all[#all + 1] = { n = v.n,
            x = v.sx / v.n, y = v.sy / v.n, z = v.sz / v.n }
    end
    table.sort(all, function(p, q)
        if p.n == q.n then
            -- 票数相同时给个确定顺序（按坐标），避免每次跑出来不一样
            if p.x ~= q.x then return p.x < q.x end
            if p.y ~= q.y then return p.y < q.y end
            return p.z < q.z
        end
        return p.n > q.n
    end)

    -- ★ 取"互相离得够远"的几个高峰: 同一个峰会被 25 厘米的格子切成好几块，
    --   不去重的话第 2 名永远是第 1 名的隔壁格，换不出新信息。
    local out = {}
    local min_gap = math.max(cell * 3.0, 100.0)
    for i = 1, #all do
        local p = all[i]
        local far = true
        for j = 1, #out do
            if dist2(p.x, p.y, p.z, out[j].x, out[j].y, out[j].z)
                < min_gap * min_gap then
                far = false
                break
            end
        end
        if far then
            out[#out + 1] = p
            if #out >= (want or Snap.MAX_OFFSET_PEAK) then break end
        end
    end
    return out, #pairs
end

-- --------------------------------------------------------------------------
-- 5. 复核
-- --------------------------------------------------------------------------

--- 细网格（复核专用）: 把参照按"复核容差大小"的格子归档，
--- 让"这一点附近有没有同类参照"从"扫一遍该类型的全部参照"变成 O(1) 查询。
---
--- ★ 为什么必须这么做: 复核要对**每个（朝向候选 × 偏移候选）**都跑一遍**全部**记录，
---   而基地里同类参照可能上千 ⇒ 暴力扫描是几百万次距离比较、每次按键卡几秒。
---   有了网格: 每个记录只查自己所在格的 3×3×3 邻域（容差 = 格边长，
---   所以"在容差内的参照"一定落在这 27 个格里，一个都漏不掉）。
local function build_grid(indexed, cell)
    local g = { cell = cell, by_type = {} }
    for t, list in pairs(indexed) do
        local tg = {}
        g.by_type[t] = tg
        for i = 1, #list do
            local a = list[i]
            local cx = math.floor(a.x / cell)
            local cy = math.floor(a.y / cell)
            local cz = math.floor(a.z / cell)
            local lx = tg[cx]
            if lx == nil then lx = {}; tg[cx] = lx end
            local ly = lx[cy]
            if ly == nil then ly = {}; lx[cy] = ly end
            local lz = ly[cz]
            if lz == nil then lz = {}; ly[cz] = lz end
            lz[#lz + 1] = a
        end
    end
    return g
end

--- 网格里找 t 类型、离 (x,y,z) 最近且在格边长以内的参照。返回 元素, 距离
local function nearest_grid(g, t, x, y, z)
    local tg = g.by_type[t]
    if tg == nil then return nil end
    local cell = g.cell
    local cx0 = math.floor(x / cell)
    local cy0 = math.floor(y / cell)
    local cz0 = math.floor(z / cell)
    local best, bestd = nil, cell * cell
    for dx = -1, 1 do
        local lx = tg[cx0 + dx]
        if lx ~= nil then
            for dy = -1, 1 do
                local ly = lx[cy0 + dy]
                if ly ~= nil then
                    for dz = -1, 1 do
                        local lz = ly[cz0 + dz]
                        if lz ~= nil then
                            for i = 1, #lz do
                                local a = lz[i]
                                local ddx, ddy, ddz = a.x - x, a.y - y, a.z - z
                                local d = ddx * ddx + ddy * ddy + ddz * ddz
                                if d <= bestd then bestd, best = d, a end
                            end
                        end
                    end
                end
            end
        end
    end
    if best == nil then return nil end
    return best, math.sqrt(bestd)
end

--- 在 (place, yaw) 下统计"有多少条记录能与同类参照对上"。
--- 返回 matched, total, 平均距离（厘米）
local function verify(recs, g, place, yaw)
    local rad = math.rad(yaw)
    local c, s = math.cos(rad), math.sin(rad)
    local matched, total, sumd = 0, 0, 0.0
    for t, rl in pairs(recs) do
        for i = 1, #rl do
            local r = rl[i]
            total = total + 1
            local wx = place.x + (r.x * c - r.y * s)
            local wy = place.y + (r.x * s + r.y * c)
            local wz = place.z + r.z
            local _, d = nearest_grid(g, t, wx, wy, wz)
            if d ~= nil then
                matched = matched + 1
                sumd = sumd + d
            end
        end
    end
    local mean = nil
    if matched > 0 then mean = sumd / matched end
    return matched, total, mean
end

--- 按类型统计复核结果（给日志看"对上的都是些什么、什么完全没对上"）
local function verify_by_type(recs, g, place, yaw)
    local rad = math.rad(yaw)
    local c, s = math.cos(rad), math.sin(rad)
    local out = {}
    for t, rl in pairs(recs) do
        local m = 0
        for i = 1, #rl do
            local r = rl[i]
            local wx = place.x + (r.x * c - r.y * s)
            local wy = place.y + (r.x * s + r.y * c)
            local wz = place.z + r.z
            local _, d = nearest_grid(g, t, wx, wy, wz)
            if d ~= nil then m = m + 1 end
        end
        out[#out + 1] = { t = t, matched = m, n = #rl }
    end
    table.sort(out, function(p, q)
        if p.matched == q.matched then
            if p.n == q.n then return p.t < q.t end
            return p.n > q.n
        end
        return p.matched > q.matched
    end)
    return out
end

-- --------------------------------------------------------------------------
-- 6. 候选生成 + 打分（★★ 这一步是"不会被格状对称骗走"的关键）
--
-- ★★★ 为什么不能只靠"偏移投票的高峰"（2026-09-29 用 tools/snap_sim.py 实测到的坑）:
--   基地的地基/墙是**格状排列**的。设真偏移是 T、当前投影偏了 e:
--   地基那一件"最近的同类参照"往往是**隔壁那一格**，于是它给出的候选
--   是 T + v（v = e 最近的格向量）—— 而**所有地基都会给出同一个 T + v**！
--   结果: 投票高峰落在 T + v 上（几千票），真正的 T 只有几十票（设施那几件）
--   ⇒ 吸附会稳定地吸到"错一格"的位置，日志看起来还特别自信。
--   （合成数据实测: 差 17.5 米时吸到了偏 8 米的位置，且复核分不低。）
--
--   正解: 候选不该由"票数"决定，而该由**最不可能认错的那几对**决定 ——
--     · 附近的同类参照越少（最好只有 1 个），这一对就越可信
--       （唯一的一台机器，最近的同类只可能是它自己）；
--     · 每个可信对直接给出一个精确候选（正确配对时它就是真偏移，误差 0）；
--     · 然后拿**全部记录的抽样**给每个候选打分，取分最高的。
--   这样"格状对称"就骗不到我们了: 错一格的候选对得上地基，但**对不上设施**。
-- --------------------------------------------------------------------------

--- 挑"打分样本": 优先挑**附近同类参照最少**的类型（它们最分得清对错），
--- 再用均匀抽样补上常见的类型（让大类型也参与打分）。
local function pick_score_samples(recs, ancs, max)
    local types = {}
    for t, rl in pairs(recs) do
        local na = 0
        if ancs[t] ~= nil then na = #ancs[t] end
        types[#types + 1] = { t = t, nr = #rl, na = na }
    end
    -- 排序键: 附近参照数为主（少 = 可信），记录数为辅
    table.sort(types, function(p, q)
        local kp, kq = p.na * 1000 + p.nr, q.na * 1000 + q.nr
        if kp == kq then return p.t < q.t end
        return kp < kq
    end)

    local out, rest = {}, {}
    for i = 1, #types do
        local e = types[i]
        local rl = recs[e.t]
        if #out + #rl <= max then
            for j = 1, #rl do out[#out + 1] = { t = e.t, r = rl[j] } end
        else
            rest[#rest + 1] = e
        end
    end
    if #out < max then
        local need = max - #out
        local total = 0
        for i = 1, #rest do total = total + #recs[rest[i].t] end
        local step = math.max(1, math.floor(total / need))
        local taken = 0
        for i = 1, #rest do
            local t = rest[i].t
            local rl = recs[t]
            local j = 1
            while j <= #rl and taken < need do
                out[#out + 1] = { t = t, r = rl[j] }
                taken = taken + 1
                j = j + step
            end
            if taken >= need then break end
        end
    end
    return out
end

--- 用抽样给一个候选位置打分（= 有多少条样本能对上）。快，用来粗筛。
local function score_samples(samples, grid, place, yaw)
    local rad = math.rad(yaw)
    local c, s = math.cos(rad), math.sin(rad)
    local m = 0
    for i = 1, #samples do
        local e = samples[i]
        local r = e.r
        local wx = place.x + (r.x * c - r.y * s)
        local wy = place.y + (r.x * s + r.y * c)
        local wz = place.z + r.z
        if nearest_grid(grid, e.t, wx, wy, wz) ~= nil then
            m = m + 1
        end
    end
    return m, #samples
end

--- 由"最可信的几对"生成候选偏移（可信 = 该类型在附近的参照数最少）。
--- 返回候选列表 { {x=,y=,z=}, ... }
local function seed_candidates(matched, ancs, yaw, want)
    local ranked = {}
    for i = 1, #matched do
        local p = matched[i]
        local t = p.a.t
        local na = 0
        if ancs[t] ~= nil then na = #ancs[t] end
        ranked[#ranked + 1] = { na = na, p = p }
    end
    table.sort(ranked, function(x, y)
        if x.na == y.na then
            -- 同级按坐标给个确定顺序，避免每次跑出来不一样
            local a, b = x.p.r, y.p.r
            if a.x ~= b.x then return a.x < b.x end
            if a.y ~= b.y then return a.y < b.y end
            return a.z < b.z
        end
        return x.na < y.na
    end)

    local rad = math.rad(yaw)
    local c, s = math.cos(rad), math.sin(rad)
    local out = {}
    for i = 1, math.min(#ranked, want) do
        local p = ranked[i].p
        out[#out + 1] = {
            x = p.a.x - (p.r.x * c - p.r.y * s),
            y = p.a.y - (p.r.x * s + p.r.y * c),
            z = p.a.z - p.r.z,
            na = ranked[i].na,
        }
    end
    return out
end

-- --------------------------------------------------------------------------
-- 7. 观测"游戏的建造网格步长"（诊断用，不改投影）
-- --------------------------------------------------------------------------

--- 从参照坐标里猜游戏用的网格步长。
---
--- ★ 为什么要有这个（路线图里写着"网格吸附必须实测游戏的吸附步长"）:
---   与其专门跑一轮实验去量，不如**就地量**: 玩家脚下就是他自己盖的基地，
---   把参照坐标的去重值排一下序、看"相邻差"里最常见的是多少，
---   那就是游戏摆放建筑时用的步长。日志里会打出来，用来定网格吸附的默认值。
function Snap.measure_grid(anchors, min_cm, max_cm)
    min_cm = min_cm or 5.0
    max_cm = max_cm or 2000.0
    local function scan(axis)
        local vals = {}
        for i = 1, #anchors do
            vals[#vals + 1] = anchors[i][axis]
        end
        table.sort(vals)
        local counts = {}
        local prev = nil
        for i = 1, #vals do
            local v = vals[i]
            if prev == nil or (v - prev) >= min_cm then
                if prev ~= nil then
                    local d = v - prev
                    if d <= max_cm then
                        local k = math.floor(d + 0.5)
                        counts[k] = (counts[k] or 0) + 1
                    end
                end
                prev = v
            end
        end
        local list = {}
        for k, n in pairs(counts) do list[#list + 1] = { cm = k, n = n } end
        table.sort(list, function(p, q)
            if p.n == q.n then return p.cm < q.cm end
            return p.n > q.n
        end)
        return list
    end
    local gx, gy = scan("x"), scan("y")
    local parts = {}
    for _, tag in ipairs({ "X", "Y" }) do
        local list = (tag == "X") and gx or gy
        local seg = {}
        for i = 1, math.min(#list, 3) do
            seg[#seg + 1] = string.format("%d厘米×%d", list[i].cm, list[i].n)
        end
        parts[#parts + 1] = string.format("%s: %s", tag,
            (#seg > 0) and table.concat(seg, "  ") or "(样本不足)")
    end
    return table.concat(parts, "    ")
end

-- --------------------------------------------------------------------------
-- 7. 主流程
-- --------------------------------------------------------------------------

--- 求解一次吸附。
---
--- bp     : 已加载的蓝图
--- place0 : 当前投影原点 { x=,y=,z=, yaw= }（世界厘米 + 度）
--- opts   : { radius_cm=, verify_cm=, min_matches=, yaw_search= }
--- 返回 result 或 nil, 原因
function Snap.solve(bp, place0, opts)
    opts = opts or {}
    local radius = tonumber(opts.radius_cm) or 2000.0
    local vtol = tonumber(opts.verify_cm) or 150.0
    local min_match = tonumber(opts.min_matches) or 3
    local yaw_search = (opts.yaw_search ~= false)
    local yaw0 = tonumber(place0.yaw) or 0.0

    if type(bp) ~= "table" then return nil, "没有蓝图" end

    -- ---- 参照收集半径: 记录都在包围盒里 ⇒ 对上的参照一定在
    --      "包围盒半径 + 配对阈值" 之内，比这更远的建筑不可能是它的对应件。
    local size = (bp.meta and bp.meta.size) or {}
    local sx = (tonumber(size.x) or 0.0) * 100.0
    local sy = (tonumber(size.y) or 0.0) * 100.0
    local sz = (tonumber(size.z) or 0.0) * 100.0
    local half_diag = 0.5 * math.sqrt(sx * sx + sy * sy + sz * sz)
    if half_diag <= 0.0 then half_diag = 5000.0 end
    local gather_r = half_diag + radius + 200.0

    -- ★ 收集这一步要碰几千个 actor —— 本 mod 历史上"崩在扫描过程中"出现过，
    --   所以先把意图落盘: 万一崩了，日志最后一行就是"正在收集参照"。
    Log.emit(string.format(
        "  [snap] 收集参照: 半径 %.0f 米（包围盒半径 %.0f 米 + 配对阈值 %.0f 米）",
        gather_r / 100.0, half_diag / 100.0, radius / 100.0))
    Log.flush()

    local anchors, ainfo = Snap.gather(place0.x, place0.y, place0.z, gather_r)
    if anchors == nil then return nil, tostring(ainfo) end
    if #anchors == 0 then
        return nil, string.format(
            "半径 %.0f 米内没有任何建筑（没法吸附）", gather_r / 100.0)
    end
    local ancs = index_anchors(anchors)
    local recs, n_rec = index_records(bp)
    if n_rec == 0 then return nil, "蓝图里没有可用的记录" end
    -- ★ 复核用的细网格（格边长 = 复核容差）: 建一次，后面所有候选都复用它。
    local grid = build_grid(ancs, vtol)

    -- 有没有"类型对得上"的可能
    local shared = 0
    for t, rl in pairs(recs) do
        if ancs[t] ~= nil then shared = shared + #rl end
    end
    if shared == 0 then
        return nil, string.format(
            "附近 %d 个建筑里没有一件和蓝图同类型（吸附要靠同类型配对）",
            #anchors)
    end

    local stride, est, types = plan_stride(recs, ancs)
    Log.emit(string.format(
        "  [snap] 参照 %d 件（关卡共 %d，半径 %.0f 米）; 蓝图 %d 件; "
        .. "同类可比 %d 件 / %d 种类型; 预计比较 %d 次",
        #anchors, ainfo.level_total or 0, gather_r / 100.0, n_rec, shared,
        #types, est))
    if ainfo.truncated ~= nil then
        Log.emit(string.format("  [snap] 参照过多，按距离截掉了 %d 件",
            ainfo.truncated))
    end

    -- ---- 第 1 轮: 在"当前投影位置 + 当前朝向"下配对
    local pairs0 = match_pairs(recs, ancs, place0, yaw0, radius, stride)
    if #pairs0 == 0 then
        return nil, string.format(
            "阈值 %.0f 米内找不到同类型的原建筑（把投影挪近一点，"
            .. "或把 snap_radius_cm 调大）", radius / 100.0)
    end
    local yaws, yaw_votes = yaw_candidates(pairs0, yaw0, yaw_search)
    Log.emit(string.format("  [snap] 第 1 轮配对 %d 对; 朝向候选 %d 个",
        #pairs0, #yaws))
    for i = 1, math.min(#yaw_votes, 3) do
        Log.emit(string.format("        朝向票 %d: %6.1f 度（%d 票）",
            i, yaw_votes[i].avg, yaw_votes[i].n))
    end
    Log.flush()

    -- ---- 对每个（朝向候选）生成候选偏移，用抽样粗筛，再对前几名做完整复核
    --
    -- ★ 候选有两个来源（缺一不可）:
    --   ① 【可信对】直接给出的精确候选 —— 这是"不被格状对称骗走"的主力；
    --   ② 投票高峰 —— 基地里"每一类都长得差不多"时（没有稀有件）唯一的线索。
    local samples = pick_score_samples(recs, ancs, Snap.SCORE_SAMPLES)
    Log.emit(string.format("  [snap] 打分样本 %d 条（优先挑同类参照最少的类型）",
        #samples))

    local scored = {}
    local seen_yaw = {}
    -- 朝向 == 当前朝向时直接复用第 1 轮的配对（省一遍扫描）
    local cache = { [yaw0] = pairs0 }
    for yi = 1, #yaws do
        local y = yaws[yi]
        local pr = cache[y]
        if pr == nil then
            pr = match_pairs(recs, ancs, place0, y, radius, stride)
        end
        if #pr > 0 then
            seen_yaw[#seen_yaw + 1] = y
            local cands = seed_candidates(pr, ancs, y, Snap.SEED_MAX)
            local peaks = offset_peaks(pr, y, Snap.MAX_OFFSET_PEAK)
            local n_seed = #cands
            for pi = 1, #peaks do
                cands[#cands + 1] = { x = peaks[pi].x, y = peaks[pi].y,
                                      z = peaks[pi].z, peak = peaks[pi].n }
            end
            for ci = 1, #cands do
                local cd = cands[ci]
                local place = { x = cd.x, y = cd.y, z = cd.z, yaw = y }
                local sc = score_samples(samples, grid, place, y)
                scored[#scored + 1] = { place = place, yaw = y, score = sc,
                    src = (ci <= n_seed) and "可信对" or "投票高峰",
                    na = cd.na, peak = cd.peak }
            end
        end
    end
    if #scored == 0 then
        return nil, "配对到了，但一个候选都算不出来"
    end

    table.sort(scored, function(p, q)
        if p.score == q.score then
            if p.place.x ~= q.place.x then return p.place.x < q.place.x end
            if p.place.y ~= q.place.y then return p.place.y < q.place.y end
            return p.place.z < q.place.z
        end
        return p.score > q.score
    end)
    Log.emit(string.format("  [snap] 候选 %d 个（%d 个朝向）; 粗筛前 5 名:",
        #scored, #seen_yaw))
    for i = 1, math.min(#scored, 5) do
        local e = scored[i]
        Log.emit(string.format(
            "        %d) 朝向 %6.1f 偏移(%.0f,%.0f,%.0f) 来源=%s 粗筛 %d/%d",
            i, e.yaw, e.place.x, e.place.y, e.place.z, e.src,
            e.score, #samples))
    end
    Log.flush()

    -- ---- 完整复核（拿**全部**记录算）前几名。先去掉彼此挨得极近的重复候选。
    local final, checked = {}, {}
    for i = 1, #scored do
        local e = scored[i]
        local dup = false
        for j = 1, #final do
            if dist2(e.place.x, e.place.y, e.place.z,
                     final[j].x, final[j].y, final[j].z)
                < Snap.DEDUP_CM * Snap.DEDUP_CM then
                dup = true
                break
            end
        end
        if not dup then
            final[#final + 1] = e.place
            local m, total, md = verify(recs, grid, e.place, e.yaw)
            Log.emit(string.format(
                "  [snap] 复核 朝向 %.1f 偏移(%.0f,%.0f,%.0f) 来源=%s → %d/%d",
                e.yaw, e.place.x, e.place.y, e.place.z, e.src, m, total))
            checked[#checked + 1] = { place = e.place, yaw = e.yaw, matched = m,
                                      total = total, mean_d = md, src = e.src }
            if #final >= Snap.FINAL_VERIFY then break end
        end
    end
    if #checked == 0 then
        return nil, "配对到了，但算不出一个能复核通过的偏移"
    end
    table.sort(checked, function(p, q) return p.matched > q.matched end)
    local best = checked[1]
    -- ★ 置信度: 第一名比第二名多对上几件？
    --   差得很少说明"基地太对称/太多重复件"，好几个位置都说得通 ——
    --   这时**必须告诉玩家**（否则他会以为吸对了，其实可能是错的那一格）。
    best.margin = best.matched
        - ((checked[2] ~= nil) and checked[2].matched or 0)
    best.ambiguous = (checked[2] ~= nil)
        and (best.margin <= math.max(2, math.floor((best.total or 0) * 0.02)))
    -- ★ 匹配率: 对上的件数 / 蓝图总件数。
    --   偏低有两种可能，**都值得看一眼**: ① 基地真的被拆过（蓝图是旧样子）；
    --   ② 没对准（基地里重复件太多、格状对称骗过了算法）。
    --   合成数据实测（tools/snap_sim.py 场景 6）: 只有地基+墙、没有任何独特件时，
    --   结果会稳定地落在"错几格"上、匹配率只有 46% —— 这一行就是那时候救命的。
    best.ratio = ((best.total or 0) > 0)
        and (best.matched / best.total) or 0.0
    best.low_coverage = best.ratio < 0.8

    -- ---- 第 2 轮: 在"复核最好的位置"上，用**更小的阈值**重新配对并取平均，
    --      把 25 厘米的投票分格误差抹掉（这一步让对齐从"差不多"变成"严丝合缝"）。
    local refine_r = math.min(radius, math.max(vtol * 3.0, 300.0))
    local pr2 = match_pairs(recs, ancs, best.place, best.yaw, refine_r, stride)
    if #pr2 > 0 then
        local pk2 = offset_peaks(pr2, best.yaw, 1)
        if #pk2 > 0 then
            local cand = { x = pk2[1].x, y = pk2[1].y, z = pk2[1].z,
                           yaw = best.yaw }
            local m2, t2, md2 = verify(recs, grid, cand, best.yaw)
            Log.emit(string.format(
                "  [snap] 精修 %.0f 米内配对 %d 对 → 复核 %d/%d（平均差 %s 厘米）",
                refine_r / 100.0, #pr2, m2, t2,
                md2 and string.format("%.1f", md2) or "-"))
            if m2 >= best.matched then
                best.place, best.matched, best.total, best.mean_d = cand, m2, t2, md2
                best.refined = true
            end
        end
    end

    -- ---- 门槛
    if best.matched < min_match then
        return nil, string.format("只对上 %d 件（至少 %d 件），没动",
            best.matched, min_match)
    end

    -- ---- 汇总
    best.anchors = #anchors
    best.records = n_rec
    best.yaw_before = yaw0
    best.yaw_after = Util.norm_yaw(best.yaw)
    best.yaw_delta = Util.norm_yaw(best.yaw_after - yaw0)
    best.dx = best.place.x - place0.x
    best.dy = best.place.y - place0.y
    best.dz = best.place.z - place0.z
    best.shift_cm = math.sqrt(best.dx * best.dx + best.dy * best.dy
        + best.dz * best.dz)
    best.by_type = verify_by_type(recs, grid, best.place, best.yaw)
    best.grid_line = Snap.measure_grid(anchors)
    Snap.last = best
    return best
end

--- 一行摘要（给日志/屏幕提示用）
function Snap.describe(res)
    if res == nil then return "(没有吸附结果)" end
    return string.format(
        "对上 %d/%d 件（平均差 %s 厘米）; 移动 %.0f 厘米; 朝向 %.1f° → %.1f°",
        res.matched, res.total or res.records or 0,
        res.mean_d and string.format("%.1f", res.mean_d) or "-",
        res.shift_cm or 0.0,
        res.yaw_before or 0.0, res.yaw_after or 0.0)
end

--- 详细报告（写日志用）
function Snap.report_lines(res)
    local out = {}
    if res == nil then return { "(没有吸附结果)" } end
    out[#out + 1] = "建筑吸附结果:"
    out[#out + 1] = string.format("  参照建筑 %d 件（同类可比）; 蓝图 %d 件",
        res.anchors or 0, res.records or 0)
    out[#out + 1] = string.format(
        "  复核: %d / %d 件对上了（容差内平均差 %s 厘米）",
        res.matched, res.total or res.records or 0,
        res.mean_d and string.format("%.1f", res.mean_d) or "-")
    out[#out + 1] = string.format(
        "  偏移增量: (%.0f, %.0f, %.0f) 厘米   共 %.0f 厘米",
        res.dx or 0.0, res.dy or 0.0, res.dz or 0.0, res.shift_cm or 0.0)
    out[#out + 1] = string.format("  朝向: %.1f° → %.1f°（%+.1f°）%s",
        res.yaw_before or 0.0, res.yaw_after or 0.0, res.yaw_delta or 0.0,
        res.refined and "（已精修）" or "")
    if res.ambiguous then
        out[#out + 1] = string.format(
            "  ⚠ 置信度低: 还有另一个位置也对上 %d 件（只差 %d 件）——"
            .. "基地里重复件太多时会有多个位置都说得通，请用眼睛确认一下"
            .. "（不合适就按 NUM 5 清零重来）。",
            res.matched - (res.margin or 0), res.margin or 0)
    end
    if res.low_coverage then
        out[#out + 1] = string.format(
            "  ⚠ 匹配率只有 %.0f%%（%d / %d）—— 要么基地确实缺件（蓝图是旧样子），"
            .. "要么没对准。请看一眼投影里的建筑和现场是不是重合的。",
            (res.ratio or 0.0) * 100.0, res.matched, res.total or 0)
    end
    if type(res.by_type) == "table" then
        out[#out + 1] = "  对上最多的类型:"
        for i = 1, math.min(#res.by_type, 5) do
            local e = res.by_type[i]
            if e.matched > 0 then
                out[#out + 1] = string.format("    %-34s %d / %d",
                    e.t, e.matched, e.n)
            end
        end
        -- ★ 一件都没对上的类型也要列出来 —— 那正是"投影里多出来的东西"
        --   （换了存档/基地被拆过时最常见），比只看匹配数有用得多。
        local miss = {}
        for i = 1, #res.by_type do
            local e = res.by_type[i]
            if e.matched == 0 then miss[#miss + 1] = e end
        end
        if #miss > 0 then
            out[#out + 1] = string.format("  完全没对上的类型（前 5，共 %d 种）:", #miss)
            for i = 1, math.min(#miss, 5) do
                out[#out + 1] = string.format("    %-34s 0 / %d",
                    miss[i].t, miss[i].n)
            end
        end
    end
    if res.grid_line ~= nil then
        out[#out + 1] = "  观测到的坐标间隔（用来定「网格吸附」的步长）: "
            .. tostring(res.grid_line)
    end
    return out
end

return Snap
