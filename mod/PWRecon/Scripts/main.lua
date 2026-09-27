--[[ ============================================================================
  PWRecon  —  建筑导出（v0.7 功能保留） + 最小化世界自检

  ============================================================================
  为什么侦察部分被"降级"到最小
  ============================================================================

  2026-09-26 连续崩了 3 次游戏，都是按热键触发。复盘：

    1) 第一次：我的拼装脚本误删函数定义 → Lua 报错 → 崩
       → 已加 tools/luacheck.py 兜住这类问题（部署前必须跑）
    2) 后两次：在【世界重载/读档】窗口读引擎对象 → 原生访问违例
       → 崩溃日志 SecondsSinceStart=40，正好是 world reload 期间

  所以本版本：

    ★ 导出功能（Y/U/H/J/K/L）保持 v0.7 原样 —— 它是验证过能用的
    ★ 侦察只留【一个】最小只读操作（按 N），每步独立 pcall + 立刻落盘
    ★ 不调用任何改状态的方法
    ★ 不做多参数/struct/spawn/材质 等任何有风险的探测

  ============================================================================
  键位
  ============================================================================

    Y  设定/更新框选中心（站在据点里按）
    K  框选半径 +25 米        L  框选半径 -25 米
    J  导出【框选框内】建筑（推荐）
    H  导出【玩家附近】       U  导出【全部建筑】
    N  世界状态自检 -> worldcheck.txt（诊断用，只读）

  ============================================================================
  按 N 的正确时机（重要）
  ============================================================================

    1. 进游戏，【完整读档进入世界】
    2. 等到你能自由走动、画面稳定 —— 不要在载入画面或刚进世界的几秒内按
    3. 原地站 5 秒
    4. 按 N → 写 worldcheck.txt

  N 会分 6 步逐项检查，每步做完立刻落盘。
  所以如果文件只写了一半，【下一步就是崩溃点】，据此可精确定位。

  ============================================================================
  输出
  ============================================================================

    buildings_raw.tsv   建筑导出（Python 工具 blueprint.py 解析）
    worldcheck.txt      世界自检结果
============================================================================ ]]

local TAG = "[PWRecon]"

-- ============================================================================
-- 配置
-- ============================================================================

local OUT_FILE = "buildings_raw.tsv"

local DEFAULT_RADIUS = 150
local RADIUS_STEP = 25
local MIN_RADIUS = 25
local MAX_RADIUS = 2000

local FLUSH_EVERY = 200

-- ============================================================================
-- 基础设施
-- ============================================================================

local ScriptDir = nil
do
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    src = src:gsub("^@", "")
    ScriptDir = src:match("^(.*)[/\\][^/\\]*$") or "."
end

local function toAscii(s)
    s = tostring(s)
    local b = {}
    for i = 1, #s do
        local c = s:byte(i)
        if c >= 32 and c <= 126 then b[#b + 1] = string.char(c)
        elseif c >= 128 then b[#b + 1] = "?" end
    end
    return table.concat(b)
end

-- 输出缓冲：out() 同时写缓冲和控制台，flush() 落盘
local lines = {}

local function out(s)
    s = tostring(s)
    table.insert(lines, s)
    print(TAG .. " " .. toAscii(s))
end

local function writeUtf8BomFile(path, text)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write("\239\187\191")
    f:write(text)
    f:close()
    return true
end

local function flush(name)
    local path = ScriptDir .. "\\" .. name
    local ok = writeUtf8BomFile(path, table.concat(lines, "\r\n"))
    print(TAG .. (ok and " wrote: " or " WRITE FAILED: ") .. path)
    return ok
end

local function reset()
    lines = {}
end

-- ============================================================================
-- 取数（导出用；均为已验证可用的只读操作）
-- ============================================================================

local function num(v, key)
    if v == nil then return nil end
    local x = nil
    pcall(function() x = v[key] end)
    if type(x) == "number" then return x end
    return nil
end

local function worldPos(obj)
    local ok, loc = pcall(function() return obj:K2_GetActorLocation() end)
    if not ok or loc == nil then return nil end
    local x, y, z = num(loc, "X"), num(loc, "Y"), num(loc, "Z")
    if x == nil then return nil end
    return x, y or 0, z or 0
end

local function yawOf(obj)
    local ok, rot = pcall(function() return obj:K2_GetActorRotation() end)
    if not ok or rot == nil then return 0 end
    return num(rot, "Yaw") or 0
end

local function shortType(obj)
    local ok, cls = pcall(function() return obj:GetClass():GetFullName() end)
    if not ok or not cls then return "Unknown" end
    local s = tostring(cls)
    local last = s:match("([^%.]+)$") or s
    last = last:gsub("_C$", "")
    last = last:gsub("^BP_BuildObject_", "")
    return last
end

local function meshOf(obj)
    local okC, comp = pcall(function() return obj.Mesh end)
    if not okC or comp == nil then return nil end
    if not pcall(function() return comp:GetFullName() end) then return nil end
    local okM, asset = pcall(function() return comp.StaticMesh end)
    if not okM or asset == nil then return nil end
    local okA, full = pcall(function() return asset:GetFullName() end)
    if not okA or not full then return nil end
    return tostring(full):match("([^%.]+)$")
end

local function objTag(obj, prop)
    local ok, o = pcall(function() return obj[prop] end)
    if not ok or o == nil then return nil end
    local okF, full = pcall(function() return o:GetFullName() end)
    if not okF or not full then return nil end
    return tostring(full):match("([^%.]+)$") or tostring(full)
end

--- 取玩家位置（导出筛选用）
-- 注意：只取位置，不读 .Pawn 之外的字段；全程 pcall
local function playerPos()
    local ok, res = pcall(function()
        local pcs = FindAllOf("PlayerController")
        if not pcs or #pcs == 0 then return nil end
        local pc = pcs[1]
        if pc == nil then return nil end
        local okP, pawn = pcall(function() return pc.Pawn end)
        if not okP or pawn == nil then return nil end
        return pawn
    end)
    if not ok or res == nil then return nil end
    local x, y, z = worldPos(res)
    if x == nil then return nil end
    return x, y, z
end

-- ============================================================================
-- 框选状态
-- ============================================================================

local sel = {
    active = false,
    cx = nil, cy = nil, cz = nil,
    radius = DEFAULT_RADIUS,
}

local function describeSel()
    if sel.cx == nil then
        return string.format("框选: 未设中心, 半径 %d 米", sel.radius)
    end
    return string.format("框选: 中心 (%.1f, %.1f, %.1f) 米, 半径 %d 米",
        sel.cx / 100.0, sel.cy / 100.0, sel.cz / 100.0, sel.radius)
end

-- ============================================================================
-- 导出建筑
-- ============================================================================

local function exportBuildings(mode, cx, cy, cz, radiusM, label)
    local path = ScriptDir .. "\\" .. OUT_FILE

    out("")
    out("================ 导出建筑 ================")
    out(string.format("模式=%s  范围=%s", mode, label or ""))

    local ok, objs = pcall(FindAllOf, "PalBuildObject")
    if not ok or not objs or #objs == 0 then
        out("!! FindAllOf(\"PalBuildObject\") 没拿到实例")
        return
    end
    local total = #objs
    out(string.format("游戏内建筑总数 = %d", total))

    if mode == "sphere" and cx == nil then
        out("!! 没有框选中心。先按 Y 设定中心（站在据点里按 Y）")
        return
    end

    local r2 = nil
    if mode == "sphere" then
        local rcm = radiusM * 100.0
        r2 = rcm * rcm
        out(string.format("筛选中心 (%.1f, %.1f, %.1f) 米  半径 %d 米",
            cx / 100.0, cy / 100.0, cz / 100.0, radiusM))
    end

    local f = io.open(path, "wb")
    if not f then
        out("!! 无法写入 " .. path)
        return
    end
    f:write("\239\187\191")
    f:write(string.format(
        "#PWBUILD|version=1|units=cm|total=%d|mode=%s|center=%.1f,%.1f,%.1f|radius=%d|time=%s\r\n",
        total, mode, cx or 0, cy or 0, cz or 0, radiusM or 0,
        tostring(os.time and os.time() or 0)))
    f:write("#type\tx\ty\tz\tyaw\tmesh\tbaseCampId\tgroupId\townerId\r\n")

    local written, skipped, noPos = 0, 0, 0
    local buf = {}

    for i = 1, total do
        local o = objs[i]
        local x, y, z = worldPos(o)
        if x == nil then
            noPos = noPos + 1
        else
            local keep = true
            if mode == "sphere" then
                local dx, dy, dz = x - cx, y - cy, z - cz
                keep = (dx * dx + dy * dy + dz * dz) <= r2
            end
            if keep then
                buf[#buf + 1] = string.format(
                    "%s\t%.2f\t%.2f\t%.2f\t%.2f\t%s\t%s\t%s\t%s\r\n",
                    shortType(o), x, y, z, yawOf(o),
                    meshOf(o) or "-", "-", "-",
                    objTag(o, "MapObjectModel") or "-")
                written = written + 1
                if #buf >= FLUSH_EVERY then
                    f:write(table.concat(buf)); buf = {}
                end
            else
                skipped = skipped + 1
            end
        end
    end
    if #buf > 0 then f:write(table.concat(buf)) end
    f:close()

    out("")
    out(string.format("写入 %d 条，跳过 %d 条，取不到坐标 %d 条",
        written, skipped, noPos))
    out("文件: " .. path)
    if written == 0 then
        out("!! 一条都没写入。半径可能太小，用 K 调大；或站到据点中心按 Y 重设中心。")
    else
        out("电脑上运行:")
        out("  python tools/blueprint.py raw <该文件> -o out/my-base.blueprint.json")
    end
end

-- ============================================================================
-- 导出热键
-- ============================================================================

local function onY()
    local px, py, pz = playerPos()
    if px then
        sel.active = true
        sel.cx, sel.cy, sel.cz = px, py, pz
        out("")
        out(">> 框选中心已设为当前位置")
    else
        sel.active = false
        out("")
        out("!! 拿不到玩家位置（要先站进世界）。框选未开启。")
    end
    out("   " .. describeSel())
    out(string.format("   K = 半径 +%d    L = 半径 -%d    J = 导出框内    Y = 重设中心",
        RADIUS_STEP, RADIUS_STEP))
end

local function onU()
    out("")
    out(">> 导出【全部】建筑")
    exportBuildings("all", nil, nil, nil, 0, "全部")
end

local function onH()
    local px, py, pz = playerPos()
    if px == nil then
        out("")
        out("!! 拿不到玩家位置")
        return
    end
    out("")
    out(string.format(">> 导出【玩家附近】半径 %d 米", sel.radius))
    exportBuildings("sphere", px, py, pz, sel.radius,
        string.format("玩家附近 %d 米", sel.radius))
end

local function onJ()
    out("")
    out(">> 导出【框选框内】建筑")
    exportBuildings("sphere", sel.cx, sel.cy, sel.cz, sel.radius, describeSel())
end

local function onK()
    sel.radius = math.min(MAX_RADIUS, sel.radius + RADIUS_STEP)
    out("")
    out(">> 半径 -> " .. sel.radius .. " 米")
    out("   " .. describeSel())
end

local function onL()
    sel.radius = math.max(MIN_RADIUS, sel.radius - RADIUS_STEP)
    out("")
    out(">> 半径 -> " .. sel.radius .. " 米")
    out("   " .. describeSel())
end

local function onHelp()
    out("")
    out("================ PWRecon 用法 ================")
    out("  Y  设定/更新框选中心（站在据点里按）")
    out("  K  半径 +" .. RADIUS_STEP .. " 米      L  半径 -" .. RADIUS_STEP .. " 米")
    out("  J  导出【框选框内】建筑  <-- 推荐用法")
    out("  H  导出【玩家附近】(半径 = 当前框选半径)")
    out("  U  导出【全部建筑】")
    out("  N  世界状态自检 -> worldcheck.txt（诊断用）")
    out("")
    out("  推荐流程: 站到据点中心 -> 按 Y -> 按 K/L 调半径 -> 按 J 导出")
    out("")
    out("  当前 " .. describeSel())
    out("  输出目录: " .. ScriptDir)
end

-- ============================================================================
-- 世界状态自检（最小只读，每步独立 pcall + 立刻落盘）
--
-- 设计意图：如果文件只写到第 K 步，那第 K+1 步就是崩溃点。
-- 这样即使崩了，也能精确定位是哪一次引擎调用出的问题。
-- ============================================================================

local function onWorldCheck()
    reset()
    out("================ worldcheck ================")
    out("时间: " .. tostring(os.time and os.time() or 0))
    out("")
    out("每步独立 pcall + 立刻落盘。文件若只写到某步，那下一步就是崩溃点。")
    out("")

    -- 步骤 1: World
    out("[1] FindAllOf(\"World\")")
    local ok1, worlds = pcall(FindAllOf, "World")
    out("    ok=" .. tostring(ok1) ..
        "  数量=" .. tostring(ok1 and worlds and #worlds or "?"))
    flush("worldcheck.txt")

    -- 步骤 2: PlayerController 计数（不读字段）
    out("")
    out("[2] FindAllOf(\"PlayerController\") —— 只计数，不读字段")
    local ok2, pcs = pcall(FindAllOf, "PlayerController")
    out("    ok=" .. tostring(ok2) ..
        "  数量=" .. tostring(ok2 and pcs and #pcs or "?"))
    flush("worldcheck.txt")

    -- 步骤 3: 读 pc[1] 的 FullName（不碰 .Pawn）
    out("")
    out("[3] pc[1]:GetFullName() —— 仍不碰 .Pawn")
    local pc = nil
    if ok2 and pcs and #pcs > 0 then
        pc = pcs[1]
        local ok3, full = pcall(function() return pc:GetFullName() end)
        out("    ok=" .. tostring(ok3) .. "  值=" .. tostring(full))
    else
        out("    (没有 PlayerController，跳过)")
    end
    flush("worldcheck.txt")

    -- 步骤 4: 读 .Pawn 属性本身（上次崩溃的嫌疑点）
    out("")
    out("[4] pc[1].Pawn —— 上次崩溃的嫌疑点")
    local pawn = nil
    if pc ~= nil then
        local ok4, p = pcall(function() return pc.Pawn end)
        out("    ok=" .. tostring(ok4))
        if ok4 and p ~= nil then
            pawn = p
            local ok4b, pf = pcall(function() return pawn:GetFullName() end)
            out("    Pawn 名字: " .. tostring(ok4b and pf or "读取失败"))
        else
            out("    Pawn 空或失败: " .. tostring(p))
        end
    else
        out("    (跳过)")
    end
    flush("worldcheck.txt")

    -- 步骤 5: 读 Pawn 位置（已验证可用的 getter）
    out("")
    out("[5] pawn:K2_GetActorLocation()")
    if pawn ~= nil then
        local x, y, z = worldPos(pawn)
        if x then
            out(string.format("    ok=true  位置(米) = %.1f, %.1f, %.1f",
                x / 100, y / 100, z / 100))
        else
            out("    ok=false（读取失败）")
        end
    else
        out("    (没有 Pawn，跳过)")
    end
    flush("worldcheck.txt")

    -- 步骤 6: 数建筑
    out("")
    out("[6] FindAllOf(\"PalBuildObject\") —— 只计数")
    local ok6, builds = pcall(FindAllOf, "PalBuildObject")
    out("    ok=" .. tostring(ok6) ..
        "  数量=" .. tostring(ok6 and builds and #builds or "?"))
    flush("worldcheck.txt")

    out("")
    out("================ 全部步骤完成 ================")
    out("文件完整写到此处 = 所有只读操作都安全。")
    flush("worldcheck.txt")
end

-- ============================================================================
-- 注册
-- ============================================================================

print(TAG .. " ==============================================")
print(TAG .. " PWRecon loaded (export + minimal world check)")
print(TAG .. " Y/U/H/J/K/L = building export    N = world check")
print(TAG .. " ==============================================")

local function tryBind(label, fn)
    local ok = pcall(RegisterKeyBindAsync, Key[label], {}, fn)
    if ok then print(TAG .. " " .. label .. " bound OK") return true end
    ok = pcall(RegisterKeyBind, Key[label], fn)
    if ok then print(TAG .. " " .. label .. " bound OK (sync)") return true end
    print(TAG .. " " .. label .. " BIND FAILED")
    return false
end

tryBind("Y", onY)
tryBind("U", onU)
tryBind("H", onH)
tryBind("J", onJ)
tryBind("K", onK)
tryBind("L", onL)
tryBind("N", onWorldCheck)
tryBind("F7", onHelp)

print(TAG .. " ----------------------------------------------")
print(TAG .. " Y/K/L/J=selection  H=near  U=all  N=worldcheck  F7=help")
print(TAG .. " ----------------------------------------------")
