--[[ ===========================================================================
  PWPR · resume —— **记住每张蓝图的每一处"投影放在哪 + 已经建到哪"**

  玩家 2026-09-29 需求（三轮迭代后的最终形态）:
    ① 「上次没建完，退出（或返回标题，或去别处加载了别的蓝图）。再回头继续建时，
        投影按玩家面朝向放 ⇒ 和已经建好的对不上。能不能存一下，
        在一定范围内重新加载时**可以选择**是否沿用上一次的位置。」
    ② 「你中间放置时不是会记录哪些已经放过了不再投影吗，这个内容不需要记录下来吗」
       ⇒ 进度也要记。
    ③ 「一张蓝图只会保存一份记录 —— 我在 A 位置投影并放置了部分建筑；再换到不在检测
        范围内的 B 位置重新投影并放置；回到 A 重新加载投影，不能放到对应位置，
        也没有原来的进度。」
       ⇒ **一张蓝图要能存多处记录**（A、B 各自独立）。
    ④ 「在 C 位置放置了部分建筑；在 C 范围内的 C2 重新加载投影，默认用 C 的位置和进度
        （这个没问题）；但**按了 H 把投影移到脚下（C2）之后，C 的位置和进度就都没了**。
        我的想法是**真的放置过建筑、有放置进度的都存下来**……
        重新加载时提示有多次放置的记录，重复按键可以切换记录，
        或者移动到当前位置（可以复用 H 键）。」
       ⇒ `H` **不再覆盖**：它把"脚下"作为**新的一处记录**，并且**把进度带过去**；
         旧的那处原样留着。另有 `B` 键在多处记录之间循环切换。

  ★ 数据结构
      entries[蓝图文件名] = { sites = { site, ... } }
      site = { x,y,z, yaw, ox,oy,oz, sx,sy,sz, t, placed = { [记录序号] = true } }
    · x/y/z    = 锚点（绝对世界坐标，按 K / 按 H 时的玩家位置）
    · yaw      = 投影朝向
    · ox/oy/oz = 微调偏移（厘米）
    · sx/sy/sz = 蓝图尺寸（厘米）—— 用来算"还在不在那片范围里"
    · placed   = **进度**（哪些记录已经放上了）

  ★ "是不是同一处"用**蓝图包围盒 + 容许距离**判定（玩家建议）:
    · 取 max(尺寸x, 尺寸y) 当正方体边长 ⇒ 与朝向无关，一定包得住；
    · 再往外放宽 `ghost_resume_margin_m`（默认 20 米）；
    · 命中多处的，取"水平距离最近"的那一处。

  ★ 只留"有意义的记录"（玩家明确要求: 不是投影了就算）
    · **有进度**（真放置过建筑）的记录: 全留，并且会在提示里报"这张蓝图有 N 处记录"；
    · 没有进度的: 每张蓝图**只留最新的一条**（就是为了"沿用上次位置"这个原始需求）。
    ⇒ 记录列表不会被"随手按了几次 K"塞满。

  ★ 写盘策略（玩家明确要求: **别每次放置都写文件**）:
    · 放置/微调/进度变化只改**内存** + 标 dirty（几乎零开销）；
    · 自续定时器（默认 10 秒）批量落盘；另外在**收起投影 / 按 F8 / 攒够 20 次改动**时立刻落。
=========================================================================== ]]

local Util = require("pwpr_util")
local Log = require("pwpr_log")

local Resume = {}

Resume.FILE = "pwpr_placements.json"
Resume.MAX_ENTRIES = 200          -- 最多记多少张蓝图
Resume.MAX_SITES = 8              -- 每张蓝图最多留几处（有进度的优先留）
Resume.SAME_SITE_CM = 1000.0      -- 锚点离这么近就当成"同一处"（更新它，而不是新建）
Resume.save_interval_s = 10.0
Resume.save_dirty_limit = 20
Resume.dirty_n = 0
Resume.dirty = false
Resume.loaded = false
Resume.path = nil
Resume.entries = {}               -- [蓝图文件名] = { sites = { site, ... } }
Resume.current = nil              -- { bp_file = "...", site = <site> } 当前正在用的那一处
Resume.last_note = nil

local function now_s()
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" then return t end
    return 0
end

local function new_site()
    return { x = 0.0, y = 0.0, z = 0.0, yaw = 0.0, ox = 0.0, oy = 0.0, oz = 0.0,
             sx = 0.0, sy = 0.0, sz = 0.0, t = 0, placed = {} }
end

local function count_placed(site)
    local n = 0
    if type(site) == "table" and type(site.placed) == "table" then
        for _ in pairs(site.placed) do n = n + 1 end
    end
    return n
end

function Resume.init(dir)
    if dir == nil then return false end
    Resume.path = tostring(dir) .. "\\" .. Resume.FILE
    -- ★ 设好路径之后**强制重新读一次**: 万一在 init 之前有人调用过 load()，
    --   这里也能把状态纠正回来（幂等，重复调用没有副作用）。
    Resume.loaded = false
    Resume.load()
    return true
end

--- 把一条读进来的表规整成 site（兼容 v1 的单条格式）
local function coerce_site(v)
    if type(v) ~= "table" then return nil end
    if tonumber(v.x) == nil or tonumber(v.y) == nil or tonumber(v.z) == nil then
        return nil
    end
    local s = new_site()
    s.x, s.y, s.z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
    s.yaw = tonumber(v.yaw) or 0.0
    s.ox = tonumber(v.ox) or 0.0
    s.oy = tonumber(v.oy) or 0.0
    s.oz = tonumber(v.oz) or 0.0
    s.sx = tonumber(v.sx) or 0.0
    s.sy = tonumber(v.sy) or 0.0
    s.sz = tonumber(v.sz) or 0.0
    s.t = tonumber(v.t) or 0
    if type(v.placed) == "table" then
        for _, idx in ipairs(v.placed) do
            local i = tonumber(idx)
            if i ~= nil then s.placed[i] = true end
        end
    end
    return s
end

--- 读盘（只读一次；失败只记日志，不影响任何功能）
function Resume.load()
    if Resume.loaded then return true end
    -- ★★★ 2026-09-29 玩家实测抓到的**第 7 个真 bug**（表现: 记录文件里明明有 3 处记录，
    --   但游戏里"这一片还没有记录"、每次按 K/H 都把"已放上"名单清零 ⇒ 建过的又被画出来）:
    --   这里原来先 `Resume.loaded = true`，**再**判断 `path == nil`。
    --   而任何在 `Resume.init()` 之前发生的调用（插件加载顺序、定时器、别的回调）
    --   都会走到"path 为空"这一支 ⇒ 返回 false，但 `loaded` 已经被置成 true
    --   ⇒ **真正的读盘被永久跳过**，整个位置/进度记忆静默失效 ✗✗
    --   ⇒ 现在: path 还没设时**不置 loaded**，等 init 之后自然会真的读一次。
    if Resume.path == nil then return false end
    Resume.loaded = true
    local text, err = Util.read_file(Resume.path)
    if text == nil or text == "" then
        Resume.last_note = "还没有历史记录（" .. tostring(err) .. "）"
        return true
    end
    local Json = nil
    pcall(function() Json = require("pwpr_json") end)
    if Json == nil then return false end
    local obj = nil
    pcall(function() obj = Json.decode(text) end)
    if type(obj) ~= "table" or type(obj.placements) ~= "table" then
        Resume.last_note = "文件内容不认识（已忽略，不影响使用）"
        Log.emit("  [resume] !! " .. Resume.last_note)
        return false
    end
    local n_bp, n_site, n_placed = 0, 0, 0
    for k, v in pairs(obj.placements) do
        if type(k) == "string" and type(v) == "table" then
            local sites = {}
            if type(v.sites) == "table" then
                for _, sv in ipairs(v.sites) do
                    local s = coerce_site(sv)
                    if s ~= nil then sites[#sites + 1] = s end
                end
            else
                local s = coerce_site(v)          -- v1 的单条格式
                if s ~= nil then sites[#sites + 1] = s end
            end
            if #sites > 0 then
                Resume.entries[k] = { sites = sites }
                n_bp = n_bp + 1
                for _, s in ipairs(sites) do
                    n_site = n_site + 1
                    n_placed = n_placed + count_placed(s)
                end
            end
        end
    end
    Resume.last_note = string.format(
        "已读入 %d 张蓝图 / %d 处位置（进度共 %d 件）", n_bp, n_site, n_placed)
    Log.emit("  [resume] " .. Resume.last_note)
    Log.flush()
    return true
end

local function entry_of(bp_file, create)
    if type(bp_file) ~= "string" or bp_file == "" then return nil end
    Resume.load()
    local e = Resume.entries[bp_file]
    if e == nil and create then
        e = { sites = {} }
        Resume.entries[bp_file] = e
    end
    return e
end

--- ★ 自愈: 需要记录时，如果内存里一张蓝图都没有、但路径是有的 ⇒ 重读一次。
---   为什么需要: 2026-09-29 那个"永久跳过加载"的 bug 让整个功能静默失效，
---   而玩家只能在游戏里看到"这一片还没有记录"。有这道保险 + 日志，
---   下次同类问题会**自己修好并且说出来**。
function Resume.ensure_loaded()
    if Resume.path == nil then
        Log.emit("  [resume] !! 还没 init（path 为空）⇒ 这次用不了记忆")
        return false
    end
    local n = 0
    for _ in pairs(Resume.entries) do n = n + 1 end
    if n > 0 then return true end
    if Resume.reload_tried then return false end
    Resume.reload_tried = true
    Resume.loaded = false
    local ok = Resume.load()
    local n2 = 0
    for _ in pairs(Resume.entries) do n2 = n2 + 1 end
    Log.emit(string.format(
        "  [resume] 内存里没有记录 ⇒ 重读了一次（%s，得到 %d 张蓝图）",
        ok and "成功" or "失败", n2))
    return n2 > 0
end

--- 这张蓝图的全部记录（按"最新在前"排）
function Resume.sites_of(bp_file)
    local e = entry_of(bp_file, false)
    if e == nil then return {} end
    local list = {}
    for _, s in ipairs(e.sites) do list[#list + 1] = s end
    table.sort(list, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return list
end

--- **有进度**的记录（按最新在前）—— "多次放置的记录"指的就是它们
function Resume.progress_sites(bp_file)
    local out = {}
    for _, s in ipairs(Resume.sites_of(bp_file)) do
        if count_placed(s) > 0 then out[#out + 1] = s end
    end
    return out
end

local function horiz(s, px, py)
    local dx, dy = s.x - px, s.y - py
    return math.sqrt(dx * dx + dy * dy)
end

--- 这一处的"范围半径"（厘米）= 蓝图包围盒的一半 + 容许距离。
--- 用 max(尺寸x, 尺寸y) 当正方体边长 ⇒ 与朝向无关，一定包得住（玩家建议）。
--- 尺寸缺失（老文件/还没算出来）时退化成"只有容许距离"。
--- ★★★ 2026-09-29 玩家实测（第 3 个问题: "只能识别 3 个位置，第 4、第 5 次都采集不到"）:
---   原来"算不算同一处"用的是**蓝图包围盒 + 容许距离**（66 米的蓝图 ⇒ 53 米半径）
---   ⇒ 玩家在同一个基地里换了几个位置，全被并进同一处 ⇒ 只认得出最早那几处 ✗
---   ⇒ 现在分成两个半径，各管各的:
---     · **登记/合并**（`bind_progress` / `remember`）= `ghost_site_merge_m`（默认 10 米）
---       —— 只有"就在这一处旁边"才算同一处；换地方建就是**新的一处** ✓
---     · **沿用**（`find_site`，按 K 时找"我属于哪一处"）= 蓝图包围盒 + 容许距离
---       —— 站基地哪一角都能认出来 ✓
local function merge_limit_cm()
    local ok, v = pcall(function() return require("pwpr_config").get("ghost_site_merge_m") end)
    local m = ok and tonumber(v) or nil
    if m == nil then m = 10.0 end
    return m * 100.0
end

local function site_limit_cm(s, margin_cm)
    local half = math.max(s.sx or 0.0, s.sy or 0.0) * 0.5
    return half + (margin_cm or 0.0)
end

--- ★ 按"**登记半径**"（`ghost_site_merge_m`，默认 10 米）找那一处 —— 找不到就返回 nil。
---   用途: 写回进度时判断"这次是在哪一处的坐标系里"（不能用 53 米的沿用半径 ✗，
---   否则会把新位置建的件换算进远处的旧记录 ⇒ 旧记录被"回填"）。
function Resume.nearest_site_within(bp_file, px, py, pz)
    if px == nil or py == nil then return nil end
    Resume.ensure_loaded()
    local e = entry_of(bp_file, false)
    if e == nil then return nil end
    local lim = merge_limit_cm()
    local best, best_d = nil, nil
    for _, s in ipairs(e.sites) do
        local d = horiz(s, px, py)
        if d <= lim and (best_d == nil or d < best_d) then best, best_d = s, d end
    end
    return best
end


--- 找"玩家现在属于哪一处"。
--- 返回 site, idx（在 progress_sites 里的序号，没有进度时为 0）, why
--- ★★★ 2026-09-29 玩家实测（问题 2 的最后一环）:
---   「先展示 A 位置的投影…移动到 B 按 H…W1 对应的位置还是没有显示」。
---   真因: "沿用哪一处"用的半径是 **蓝图包围盒 + 容许距离**（这张蓝图 33 米 + 20 米 = **53 米**）
---   ⇒ A、B 相距不到 53 米时，**B 被当成 A 的同一处** ⇒ 把 A 的记录（含 W1）套到 B 上 ✗
---   （连"按 H 清空"也会被随后的按 K 撤销 ✗）。
---   ⇒ `find_site(..., near_only = true)` 时改用 **"同一处"半径**（`ghost_site_merge_m`，默认 10 米）
---     —— 只有"就在原来那个位置"才算沿用；挪远了就是**新的放置**（放你脚下）✓
function Resume.find_site(bp_file, px, py, pz, margin_cm, near_only)
    if px == nil or py == nil or pz == nil then return nil end
    Resume.ensure_loaded()
    local sites = Resume.sites_of(bp_file)
    if #sites == 0 then
        Resume.last_note = "这张蓝图没有历史位置"
        return nil
    end
    local m = margin_cm or 0.0
    local best, best_d, best_in = nil, nil, false
    local near_lim = nil
    if near_only == true then near_lim = merge_limit_cm() end
    for _, s in ipairs(sites) do
        local half = math.max(s.sx or 0.0, s.sy or 0.0) * 0.5
        local lim = half + m
        if near_lim ~= nil then lim = near_lim end   -- ★ 只看"同一处"半径
        local d = horiz(s, px, py)
        local inside = (lim <= 0.0) or (d <= lim)
        -- 优先"在范围内"，其次"离得近"
        local better = false
        if best == nil then
            better = inside
        elseif inside and not best_in then
            better = true
        elseif inside == best_in and d < best_d then
            better = true
        end
        if better then best, best_d, best_in = s, d, inside end
    end
    if best == nil then
        Resume.last_note = "都不在范围内"
        return nil
    end
    -- 报一下"现在用的是第几处"。
    --   `idx` = **有进度的第几处**（提示语用，0 = 这一处还没进度）；
    --   `adopt` 会另外记下**稳定序号**（`U` 轮换用），两者不要混。
    local idx = 0
    for i, s in ipairs(Resume.progress_sites(bp_file)) do
        if s == best then idx = i break end
    end
    best.dist = math.sqrt((best.x - px) ^ 2 + (best.y - py) ^ 2 + (best.z - pz) ^ 2)
    if near_lim ~= nil then
        -- ★ "沿用"用的是**同一处半径**（`ghost_site_merge_m`，默认 10 米）——
        --   只有"就在原来那个位置"才算沿用；挪远了就是**新的放置** ✓
        best.why = string.format("水平 %.1f 米 ≤ 同一处半径 %.0f 米",
            best_d / 100.0, near_lim / 100.0)
    else
        best.why = string.format("水平 %.0f 米 ≤ 范围 %.0f 米 + 容许 %.0f 米%s",
            best_d / 100.0,
            (math.max(best.sx or 0.0, best.sy or 0.0) * 0.5) / 100.0,
            m / 100.0, best_in and "" or "（放宽范围内）")
    end
    Resume.adopt(bp_file, best)
    return best, idx, best.why
end

--- 把某一处设为"当前正在用"（切换记录 / 恢复进度时用）
function Resume.adopt(bp_file, site)
    if site == nil then return false end
    local idx = nil
    local e = entry_of(bp_file, false)
    if e ~= nil then
        for i, s in ipairs(e.sites) do
            if s == site then idx = i break end
        end
    end
    Resume.current = { bp_file = bp_file, site = site, index = idx }
    return true
end

--- 记"位置"（只改内存）。**不会**新建记录，除非确实没有合适的：
---   · 当前正在用的那一处（同一张蓝图）—— 直接更新它；
---   · 否则找锚点 10 米以内的一处 —— 更新它；
---   · 都没有 —— 新建一处。
--- 更新"位置"（只改内存）。**绝不新建记录** —— 记录只能由"有进度"产生
--- （见 `bind_progress`）。规则:
---   · 当前正在用的那一处，且锚点还在**它那一片范围内** ⇒ 原地更新（微调/H 挪一下）；
---   · 否则找**锚点所在范围内**的那一处（蓝图包围盒 + 容许距离）⇒ 更新它；
---   · 都不匹配 ⇒ **什么都不做**（这次的位置不写进任何记录）。
---
--- ★ 为什么要这样（玩家 2026-09-29 第三轮实测）:
---   「在 A 位置投影建造过，到 B 位置按 H……**B 位置的不重新放新建筑也记录了，
---     而且 A 位置的记录没了**」。根因是"光按 H 也会新增/覆盖记录" ⇒
---   现在记录**只跟着进度走**，光挪投影不产生任何记录 ✓
function Resume.remember(bp_file, anchor, yaw, offset, size, margin_cm)
    if type(anchor) ~= "table" or tonumber(anchor.x) == nil then return false end
    if type(bp_file) ~= "string" or bp_file == "" then return false end
    local e = entry_of(bp_file, false)
    if e == nil or #e.sites == 0 then return false end      -- 还没有任何记录 ⇒ 不动

    local site = nil
    local lim = merge_limit_cm()          -- ★ 同样用"同一处"的小半径
    -- ① 当前那一处，且锚点就在它旁边
    if Resume.current ~= nil and Resume.current.bp_file == bp_file
        and Resume.current.site ~= nil then
        local s = Resume.current.site
        if horiz(s, anchor.x, anchor.y) <= lim then site = s end
    end
    -- ② 锚点落在别的那一处旁边
    if site == nil then
        local best_d = nil
        for _, s in ipairs(e.sites) do
            local d = horiz(s, anchor.x, anchor.y)
            if d <= lim and (best_d == nil or d < best_d) then
                site, best_d = s, d
            end
        end
    end
    if site == nil then return false end                    -- 不属于任何一片 ⇒ 不记录

    -- ★★★ 2026-09-29 玩家实测（"第一次放的也找不到了"）:
    --   **已经有进度的那一处，锚点不能再被拖动** —— 它的锚点是"那批建筑所在的位置"，
    --   拖动它等于让"已建好的序号"整体平移 ⇒ 之后既藏错件、也对不上原位。
    --   （没进度的临时位置仍然可以随便挪 —— 它只是"上次投影放在哪"。）
    if count_placed(site) > 0 then
        site.t = now_s()
        Resume.adopt(bp_file, site)
        Resume.mark_dirty()
        return true
    end

    site.x, site.y, site.z = tonumber(anchor.x), tonumber(anchor.y), tonumber(anchor.z)
    site.yaw = tonumber(yaw) or 0.0
    site.ox = tonumber(offset and offset.x) or 0.0
    site.oy = tonumber(offset and offset.y) or 0.0
    site.oz = tonumber(offset and offset.z) or 0.0
    if type(size) == "table" then
        site.sx = (tonumber(size.x) or 0.0) * 100.0
        site.sy = (tonumber(size.y) or 0.0) * 100.0
        site.sz = (tonumber(size.z) or 0.0) * 100.0
    end
    site.t = now_s()
    Resume.adopt(bp_file, site)
    Resume.mark_dirty()
    return true
end

--- ★★ **把"进度"绑到当前这一片**（唯一会创建记录的入口）。
---
---   · `list` 为空 ⇒ **什么都不做**（这是修 "A 的进度被洗成 0" 的关键:
---     按 `J` 换蓝图会清空内存里的"已放上"名单，原来那个空名单会被当成
---     "这一片什么都没有"写回记录 ✗✗）；
---   · `list` 非空 ⇒ 锚点落在哪一片就写进哪一片；**不在任何一片里就新建一处**
---     （锚点 + 朝向 + 微调 + 尺寸 + 这次进度）—— 于是"记录"天然等于
---     "**真放过建筑的地方**"，与玩家要的规则一致。
---
--- 返回: ok, site, is_new
function Resume.bind_progress(bp_file, list, anchor, yaw, offset, size, margin_cm)
    if type(bp_file) ~= "string" or bp_file == "" then return false end
    if type(list) ~= "table" or #list == 0 then
        return false, nil, false            -- 空名单: 绝不动记录
    end
    Resume.ensure_loaded()
    local set = {}
    for _, idx in ipairs(list) do
        local i = tonumber(idx)
        if i ~= nil then set[i] = true end
    end
    if next(set) == nil then return false, nil, false end

    -- 先按"位置"这条规则找到所属的那一片（有就更新，没有就新建）
    local e = entry_of(bp_file, true)
    if e == nil then return false end
    local site = nil
    if type(anchor) == "table" and tonumber(anchor.x) ~= nil then
        -- ★ 用**小半径**判断"是不是同一处"（默认 10 米）—— 换地方建就是新的一处
        local lim = merge_limit_cm()
        for _, s in ipairs(e.sites) do
            if horiz(s, anchor.x, anchor.y) <= lim then
                site = s break
            end
        end
    end
    local is_new = false
    if site == nil then
        site = new_site()
        if type(anchor) == "table" and tonumber(anchor.x) ~= nil then
            site.x, site.y, site.z = tonumber(anchor.x), tonumber(anchor.y),
                tonumber(anchor.z)
        end
        site.yaw = tonumber(yaw) or 0.0
        site.ox = tonumber(offset and offset.x) or 0.0
        site.oy = tonumber(offset and offset.y) or 0.0
        site.oz = tonumber(offset and offset.z) or 0.0
        if type(size) == "table" then
            site.sx = (tonumber(size.x) or 0.0) * 100.0
            site.sy = (tonumber(size.y) or 0.0) * 100.0
            site.sz = (tonumber(size.z) or 0.0) * 100.0
        end
        e.sites[#e.sites + 1] = site
        is_new = true
        Log.emit(string.format(
            "  [resume] 新增一处记录（第 %d 处，%d 件进度）—— 只有真放过建筑的位置才会记录",
            #e.sites, #list))
    end
    site.placed = set
    site.t = now_s()
    Resume.adopt(bp_file, site)
    Resume.prune(bp_file)
    Resume.mark_dirty()
    return true, site, is_new
end

--- 只保留"有进度"的记录（顺序不变，`U` 轮换靠这个顺序）。
---
--- ★ 2026-09-29 玩家三轮实测后的规则: **记录 = 真放过建筑的地方**。
---   所以"没进度"的临时位置（内存里那份"当前指向"）不进文件、也不算一处记录。
---   同时仍然限制每张蓝图最多 MAX_SITES 处。
function Resume.prune(bp_file)
    local e = entry_of(bp_file, false)
    if e == nil then return 0 end
    local kept, dropped = {}, 0
    for _, s in ipairs(e.sites) do          -- 保持数组顺序
        if count_placed(s) > 0 and #kept < Resume.MAX_SITES then
            kept[#kept + 1] = s
        else
            dropped = dropped + 1
        end
    end
    e.sites = kept
    if dropped > 0 then
        Log.emit(string.format(
            "  [resume] 丢掉 %d 处没进度的临时位置（记录只留真放过建筑的地方）", dropped))
    end
    return dropped
end

--- ★ 循环切到"下一处记录"（`U` 键）。返回 site, 序号, 总数
---
--- ★★★ 2026-09-29 玩家实测抓到的第三个问题:
---   「我反复按 U，经常只能切换两份，要靠点运气才能切到第三份。」
---   原因: 这里原来按 **`t`（最后使用时间）排序**去数"当前是第几处"，
---   而**每次切换都会把那一处的 `t` 更新成现在** ⇒ 它永远排在第 1 位
---   ⇒ "下一处"永远是第 2 项 ⇒ 只能在两处之间来回跳 ✗
---   （日志实证: 连续 10 次 `切到第 2/6 处` 在两个锚点间交替；两个锚点相距 4.7 公里）
---   ⇒ 现在: 轮换用**稳定的数组顺序**（记录创建的顺序），当前是第几处由
---     `Resume.current.index` **显式记着**，与时间戳完全无关。
function Resume.cycle(bp_file)
    local e = entry_of(bp_file, false)
    if e == nil or #e.sites == 0 then return nil, 0, 0 end
    local all = e.sites                       -- 稳定顺序（创建顺序）
    local cur_idx = nil
    if Resume.current ~= nil and Resume.current.bp_file == bp_file then
        cur_idx = Resume.current.index
        if cur_idx == nil and Resume.current.site ~= nil then
            for i, s in ipairs(all) do
                if s == Resume.current.site then cur_idx = i break end
            end
        end
    end
    local nxt_idx = ((cur_idx or 0) % #all) + 1
    local nxt = all[nxt_idx]
    Resume.adopt(bp_file, nxt)
    return nxt, nxt_idx, #all
end

--- 进度（数组形式，喂给投影侧）
function Resume.placed_of_site(site)
    if type(site) ~= "table" or type(site.placed) ~= "table" then return nil end
    local out = {}
    for idx in pairs(site.placed) do out[#out + 1] = idx end
    table.sort(out)
    return out
end

--- 兼容旧调用: 取当前那一处的进度
function Resume.placed_of(bp_file)
    if Resume.current ~= nil and Resume.current.bp_file == bp_file then
        return Resume.placed_of_site(Resume.current.site)
    end
    local list = Resume.progress_sites(bp_file)
    if #list == 0 then return nil end
    return Resume.placed_of_site(list[1])
end

function Resume.mark_dirty()
    Resume.dirty = true
    Resume.dirty_n = Resume.dirty_n + 1
    if Resume.dirty_n >= Resume.save_dirty_limit then
        Resume.save(true)
    end
end

--- 落盘（批量）。force = true 时无视时间间隔。
function Resume.save(force)
    if Resume.path == nil then return false end
    if not Resume.dirty and force ~= true then return false end
    if not force then
        local now = os.clock()
        if (now - (Resume.last_save_clock or 0.0)) < Resume.save_interval_s then
            return false
        end
    end

    -- 太多了就丢最旧的蓝图
    local keys = {}
    for k in pairs(Resume.entries) do keys[#keys + 1] = k end
    if #keys > Resume.MAX_ENTRIES then
        table.sort(keys, function(a, b)
            local ta, tb = 0, 0
            for _, s in ipairs(Resume.entries[a].sites) do
                if (s.t or 0) > ta then ta = s.t end
            end
            for _, s in ipairs(Resume.entries[b].sites) do
                if (s.t or 0) > tb then tb = s.t end
            end
            return ta > tb
        end)
        for i = Resume.MAX_ENTRIES + 1, #keys do
            Resume.entries[keys[i]] = nil
        end
    end

    -- 手写 JSON。⚠️ 改这里的模板时，`tools/check_resume_json.py` 里的模板要一起改。
    -- ★ 只写"有进度"的记录: 没进度的那些只是内存里的"当前指向"，
    --   不落盘（玩家规则: 记录 = 真放过建筑的地方）。
    local keys2 = {}
    for k, e in pairs(Resume.entries) do
        local n_has = 0
        for _, s in ipairs(e.sites) do
            if count_placed(s) > 0 then n_has = n_has + 1 end
        end
        if n_has > 0 then keys2[#keys2 + 1] = k end
    end
    table.sort(keys2)
    local out = {}
    out[#out + 1] = "{"
    out[#out + 1] = '  "_readme": "PWProjection 记住的『每张蓝图每一处投影放在哪 + 已经建到哪』。'
        .. '一张蓝图可以有多处（sites）；有进度的都会留着，没进度的每张只留最新一条。'
        .. '删掉这个文件就等于全部忘记。坐标是绝对世界坐标，且只在玩家还处在那片范围内'
        .. '才会沿用。",'
    out[#out + 1] = "  \"placements\": {"
    local n_site, n_placed = 0, 0
    for i = 1, #keys2 do
        local k = keys2[i]
        local e = Resume.entries[k]
        local parts = {}
        for _, s in ipairs(e.sites) do
          if count_placed(s) > 0 then      -- 只写"有进度"的记录
            n_site = n_site + 1
            local idx = {}
            for n in pairs(s.placed or {}) do idx[#idx + 1] = n; n_placed = n_placed + 1 end
            table.sort(idx)
            parts[#parts + 1] = string.format(
                "{\"x\":%.1f,\"y\":%.1f,\"z\":%.1f,\"yaw\":%.1f,"
                .. "\"ox\":%.1f,\"oy\":%.1f,\"oz\":%.1f,"
                .. "\"sx\":%.1f,\"sy\":%.1f,\"sz\":%.1f,\"t\":%d,\"placed\":[%s]}",
                s.x, s.y, s.z, s.yaw or 0.0,
                s.ox or 0.0, s.oy or 0.0, s.oz or 0.0,
                s.sx or 0.0, s.sy or 0.0, s.sz or 0.0, s.t or 0,
                table.concat(idx, ","))
          end
        end
        out[#out + 1] = string.format("    %q: {\"sites\": [%s]}%s",
            k, table.concat(parts, ", "), (i < #keys2) and "," or "")
    end
    out[#out + 1] = "  }"
    out[#out + 1] = "}"
    local text = table.concat(out, "\r\n")
    local ok, err = Util.write_file(Resume.path, text .. "\r\n", true)
    if ok then
        Resume.dirty = false
        Resume.dirty_n = 0
        Resume.last_save_clock = os.clock()
        Resume.last_note = string.format(
            "已记住 %d 张蓝图 / %d 处位置（进度共 %d 件）", #keys2, n_site, n_placed)
        Log.line("  [resume] " .. Resume.last_note .. "（写盘一次）")
        return true
    end
    Resume.last_note = "写盘失败: " .. tostring(err)
    Log.emit("  [resume] !! " .. Resume.last_note)
    return false
end

function Resume.tick()
    if not Resume.dirty then return false end
    return Resume.save(false)
end

--- 状态行（F7）
function Resume.status_line()
    local n_bp, n_site, n_placed = 0, 0, 0
    for _, e in pairs(Resume.entries) do
        n_bp = n_bp + 1
        for _, s in ipairs(e.sites) do
            n_site = n_site + 1
            n_placed = n_placed + count_placed(s)
        end
    end
    return string.format("投影位置/进度记忆: %d 张蓝图 / %d 处（进度共 %d 件）（%s%s）",
        n_bp, n_site, n_placed, tostring(Resume.last_note or "还没用过"),
        Resume.dirty and "，有改动待落盘" or "")
end

return Resume
