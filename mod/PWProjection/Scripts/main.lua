--[[ ===========================================================================
  PWPR · main  ——  Palworld 蓝图投影 mod（入口）

  名字:   PWProjection          （Mods\PWProjection\Scripts\main.lua）
  控制台标签: [PWPR]

  ============================================================================
  它做什么
  ============================================================================

    采集:   把基地里的建筑读出来，存成 .blueprint.json
    蓝图库: 管理多张蓝图，循环切换
    投影:   在任意位置以半透明幽灵形式画出蓝图
    移动:   小键盘前后左右/上下微调，可旋转
    分层:   一层一层看（这是 SBB 没有的功能）

  ============================================================================
  分阶段激活（安全设计）
  ============================================================================

    S0 加载     只读配置 + 注册热键。什么都不碰引擎。
    S1 采集     FindAllOf + 读坐标/朝向。全部是 PWRecon 长期验证过的只读调用。
    S2 蓝图库   纯 Lua 文件读写。
    S3 探测     逐项验证"渲染需要的原语"，每步落盘，崩溃可定位。  <- 按 N
    S4 投影     唯一会创建引擎对象的功能。双重门禁，默认关闭。

    没有跑过 S3 并通过，S4 在结构上不可能执行（见 pwpr_ghost.check_gate）。

  ============================================================================
  按键（无修饰键的字母，都是 PWRecon 实测空着的键）
  ============================================================================

    F7   帮助 / 当前状态（含完整按键表）
    Y    采集（半径见 config capture_radius_m；设成 0 = 采集全部建筑）
    U    投影：对齐到附近的真实建筑（建筑吸附；放下投影时也会自动吸一次）
    J    蓝图库：切到下一张并加载
    K    投影：放 / 收   （收 = 彻底销毁宿主，不留残留对象；放下时会自动对齐）
    L    投影：切分层    （全部层 -> 第 0 层 -> 第 1 层 -> ... -> 全部层）
    H    投影：重新定位到你脚下（清掉偏移与旋转）
    N    渲染能力探测（S3）—— 第一次用投影前必须先跑这个
    O    屏幕提示通道探测（S9）—— 查"能不能在游戏里显示文字"

  ★ 2026-09-29 键位调整（都以玩家自己的键盘为准 —— **84 配列，没有小键盘**）:
    · 采集合并成**一个**键（原来 Y=附近 / U=全部两个键）；
    · 新增的吸附功能**不放在小键盘上**（84 配列按不到），用空出来的 U；
      有小键盘的人额外还能按小键盘 7（代码自动加别名）。

  屏幕提示: 每次操作后给一行中文提示，走 pwpr_notify（策略）+ pwpr_hud（通道）。
    兜底通道是控制台 print（零风险）；游戏内通道要先跑 O 探测并用配置显式打开。
    详见 README 第 4.6 节 与 pwpr_hud.lua 文件头。

  小键盘（放置微调）
    NUM_8 / NUM_2    往前 / 往后
    NUM_4 / NUM_6    往左 / 往右
    NUM_9 / NUM_3    抬高 / 降低
    ADD  / SUBTRACT  逆时针 / 顺时针旋转
    NUM_5            清掉偏移与旋转
    NUM_0            切换步长（10 / 50 / 100 / 500 / 1000 厘米）

  ============================================================================
  按键时机（很重要）
  ============================================================================

    前几次崩溃的成因之一是"在世界重载/读档窗口里读引擎对象"。
    所以: 完整读档、能自由走动、画面稳定之后，再按这些键。
    另外本 mod 注册了 LoadMapPre 钩子，换地图时只丢引用、不碰引擎。
=========================================================================== ]]

local ok_init, init_err = pcall(function()

-- ---------------------------------------------------------------------------
-- 依赖
-- ---------------------------------------------------------------------------

local Util     = require("pwpr_util")
local Log      = require("pwpr_log")
local Config   = require("pwpr_config")
local BP       = require("pwpr_bp")
local Capture  = require("pwpr_capture")
local Library  = require("pwpr_library")
local MeshMap  = require("pwpr_meshmap")
local Session  = require("pwpr_session")
local Ghost    = require("pwpr_ghost")
local Snap     = require("pwpr_snap")
local BuildSnap = require("pwpr_buildsnap")
local Placed = require("pwpr_placed")
local Probe    = require("pwpr_probe")
local Hud      = require("pwpr_hud")
local Notify   = require("pwpr_notify")
local Sched    = require("pwpr_sched")

local TAG = Util.TAG

-- 绑定结果（在文件靠前处声明，这样 do_help 能引用到它们。
-- ★ 注意: Lua 的 local 只对声明之后的代码可见 —— 声明放太后，
--   do_help 里引用的就是全局 nil。这个坑踩过一次，见 docs/踩坑记录.md 第 13 节。）
local bound, failed = {}, {}

-- ---------------------------------------------------------------------------
-- 放置操作模式 —— 方向键的含义随模式变化
--
-- ★ 为什么改成"模式"而不是修饰键组合（2026-09-26 实测教训）:
--   UE4SS 的 RegisterKeyBindAsync(key, {}, fn) 在**按住修饰键时照样触发**。
--   所以 "Alt+↑" 会同时触发 "Alt+↑" 和 "↑" 两个回调 ——
--   一次按键做了两件事（玩家报"Alt+方向键的同时也会移动或者旋转"）。
--   用【纯方向键 + 一个模式键】就彻底没有这个问题:
--     · 不再需要任何修饰键 → 不会和 Ctrl(闪避) / Shift(冲刺) 打架
--     · 一次只做一件事 → 不会双重触发
--     · 组合键从 16 个降到 4 个 + 1 个模式键
-- ---------------------------------------------------------------------------

local place_mode = "move"
local PLACE_MODES = { "move", "rotate", "material" }
local PLACE_MODE_LABEL = {
    move     = "移动   ↑前 ↓后 ←左 →右",
    rotate   = "旋转   ←逆时针 →顺时针 ↑抬高 ↓降低",
    material = "材质   ←→换材质  ↑换分层  ↓换步长",
}

--- 材质模式的观感速记（ASCII，控制台能看清；中文在日志里）
--- ★ 这 4 档是玩家实测挑出来的，顺序就是循环顺序
local MATERIAL_ASCII = {
    building  = "BLUE   (default)",
    error     = "RED",
    dismantle = "YELLOW (build almost complete)",
    original  = "FULL COLOR (no material override)",
    -- 不在循环里、但写进配置就能用的
    highlight = "GREY GRID",
    building2 = "BLUE (two-sided)",
    complete  = "BUILD COMPLETE",
    beforefix = "BEFORE FIX",
}
local MATERIAL_CN = {
    building  = "蓝色（默认）",
    error     = "红色",
    dismantle = "黄色（建造即将完成）",
    original  = "原始彩色（不覆盖材质）",
    highlight = "灰白格子",
    building2 = "蓝色（双面渲染）",
    complete  = "建造完成态",
    beforefix = "修复前态",
}

-- ---------------------------------------------------------------------------
-- 基础设施
-- ---------------------------------------------------------------------------

Log.init(Util.script_dir)

--- 同时写文件（中文）和控制台（ASCII 英文）
local function dual(cn, en)
    Log.line(cn .. "     [" .. en .. "]")
    if Log.echo then print(TAG .. " " .. en) end
end

--- 把函数包起来，保证任何 Lua 错误都不会跑出去。
--- 结束时打一条 ASCII 的 "<<" 标记（配合 on_game_thread 的 ">>" 用）。
local function safe(label, fn)
    return function()
        local ok, err = pcall(fn)
        if not ok then
            print(TAG .. " !! " .. label .. " ERROR: "
                .. Util.ascii(tostring(err)))
            Log.emit("!! " .. label .. " 内部出错: " .. tostring(err))
            Log.flush()
        end
        print(TAG .. " << " .. label)
    end
end

--- 包起来 + 丢到游戏线程（改动引擎的操作用这个）
---
--- ★ 诊断设计（2026-09-26 崩溃复盘后加的）：
---   ">>" 这一行是在【按键那一刻】同步打出来的，在调度之前。
---   所以只要 UE4SS.log 里出现了 ">> capture-near"，
---   就证明【键绑定生效了、回调进来了】—— 不再需要靠猜"Y 到底按下去没有"。
---   反过来，如果只有 ">>" 没有 "<<"，那崩溃就一定发生在这个处理函数里面。
local function on_game_thread(label, fn)
    local guarded = safe(label, fn)
    return function()
        print(TAG .. " >> " .. label)
        Sched.game_thread(guarded)
    end
end

--- 同上，但不丢到游戏线程（纯 Lua / 文件 IO 用这个）
local function on_direct(label, fn)
    local guarded = safe(label, fn)
    return function()
        print(TAG .. " >> " .. label)
        guarded()
    end
end

-- ---------------------------------------------------------------------------
-- 输出辅助
-- ---------------------------------------------------------------------------

local function dump_lines(lines)
    for i = 1, #lines do Log.line(lines[i]) end
end

local function emit_lines(lines)
    for i = 1, #lines do Log.emit(lines[i]) end
end

local function flush_log()
    Log.flush()
end

-- ---------------------------------------------------------------------------
-- S1 采集
-- ---------------------------------------------------------------------------

local function do_capture(mode)
    Log.clear()
    Log.section(mode == "all" and "采集：全部建筑" or "采集：玩家附近")

    local filter = { mode = mode }
    local label = "全部"

    if mode == "sphere" then
        local px, py, pz = Session.player_pos()
        if px == nil then
            Log.emit("!! 拿不到玩家位置。请先完整进入世界并站稳。")
            Notify.show("采集失败: 拿不到你的位置（先进世界站稳）",
                "capture failed: no player position", "error")
            flush_log()
            return
        end
        local radius_m = tonumber(Config.get("capture_radius_m")) or 150
        filter.cx, filter.cy, filter.cz = px, py, pz
        filter.radius_cm = radius_m * 100.0
        label = string.format("玩家附近 %d 米", radius_m)
        Log.emit(string.format("中心 (%.1f, %.1f, %.1f) 米   半径 %d 米",
            px / 100, py / 100, pz / 100, radius_m))
    end

    -- 在碰引擎之前，先把"我要开始扫了"落盘。
    -- 崩溃复盘时这一行就是分界线：有它没后续 = 崩在引擎调用里。
    Log.emit(">> 开始扫描引擎对象（这一步会短暂卡顿）")
    Log.flush()

    -- 进度回调：每 500 件落一次盘。
    -- 这样万一扫描途中崩了，pwpr.log 里能看到"扫到第几件"，
    -- 而不是像 18:02 那次一样什么都留不下。
    local records, info = Capture.scan(filter, function(done, total)
        if done % 500 == 0 then
            Log.emit(string.format("  ... 已扫描 %d/%d", done, total))
            Log.flush()
        end
    end)
    if info.list_error ~= nil then
        Log.emit("!! 列举建筑失败: " .. tostring(info.list_error))
        Notify.show("采集失败: 列不出建筑（看日志）", "capture failed: cannot list buildings", "error")
        flush_log()
        return
    end

    Log.emit(string.format(
        "游戏内建筑 %d 件 -> 选中 %d 件（范围外 %d，坐标读不到 %d，无效 %d）",
        info.total, info.kept, info.skipped, info.no_position, info.invalid))

    if #records == 0 then
        Log.emit("!! 一件都没选中。")
        Log.emit("   · 按 Y 用「玩家附近」采集时，半径可能太小（改 config capture_radius_m）")
        Notify.show("采集: 一件都没选中（半径太小？或这里本来没建筑）",
            "capture: nothing selected", "error")
        Log.emit("   · 或者你站的地方本来就没有建筑")
        flush_log()
        return
    end

    local maxn = tonumber(Config.get("capture_max")) or 6000
    if #records > maxn then
        Log.emit(string.format("!! 选中 %d 件，超过 capture_max = %d，已中止。",
            #records, maxn))
        Notify.show(string.format("采集: %d 件超过上限 (capture_max=%d)，已中止",
            #records, maxn), "capture aborted: over capture_max", "error")
        flush_log()
        return
    end

    -- 名字用原点坐标，重采同一个基地会覆盖同一份文件（不会堆积垃圾）
    local function name_for(bp)
        local o = bp.meta.origin
        return string.format("%s_%.0f_%.0f",
            mode == "all" and "all" or "base", o[1], o[2])
    end

    -- 先建一次拿原点，用于命名；再正式建一次（名字要写进 meta）
    local probe_bp, berr = BP.build(records, {
        name = "tmp",
        layerGapCm = Config.get("layer_gap_cm"),
        snapM = Config.get("origin_snap_m"),
    })
    if probe_bp == nil then
        Log.emit("!! 生成蓝图失败: " .. tostring(berr))
        Notify.show("采集失败: 生成蓝图出错（看日志）", "capture failed: build error", "error")
        flush_log()
        return
    end

    local final_name = name_for(probe_bp)
    local bp, err = BP.build(records, {
        name = final_name,
        source = "PWProjection (UE4SS)",
        layerGapCm = Config.get("layer_gap_cm"),
        snapM = Config.get("origin_snap_m"),
    })
    if bp == nil then
        Log.emit("!! 生成蓝图失败: " .. tostring(err))
        flush_log()
        return
    end

    local okv, errors, warnings = BP.validate(bp)
    if not okv then
        Log.emit("!! 自检未通过（不会保存）:")
        emit_lines(errors)
        Notify.show(string.format("采集: 自检没通过（%d 个错误），没有保存", #errors),
            "capture: validation failed, not saved", "error")
        flush_log()
        return
    end
    if #warnings > 0 then
        Log.emit(string.format("自检警告 %d 条:", #warnings))
        for i = 1, math.min(#warnings, 8) do Log.emit("  " .. warnings[i]) end
    end

    local path, werr = Library.save(final_name, bp)
    if path == nil then
        Log.emit("!! 保存失败: " .. tostring(werr))
        Notify.show("采集: 保存文件失败（看日志）", "capture: save failed", "error")
        flush_log()
        return
    end

    emit_lines(BP.summary_lines(bp, 10))
    Log.emit("")
    Log.emit("已保存: " .. path)

    -- ★ 自检输出（2026-09-28 加）: 有网格名、却一个 mesh_path 都没写出来。
    --   这正是"跨存档投影缺件"的根因长相，而采集日志其余部分一切正常 ——
    --   所以必须在这里**明确喊出来**，否则只能靠人去翻蓝图文件才发现。
    local mc = (type(bp.meta) == "table") and bp.meta.meshCoverage or nil
    if type(mc) == "table" then
        Log.emit(string.format("网格覆盖: 有网格 %s / 有完整路径 %s / 共 %s 件",
            tostring(mc.withMesh), tostring(mc.withPath), tostring(mc.total)))
        if bp.meta.meshPathWarn ~= nil then
            Log.emit("!! " .. tostring(bp.meta.meshPathWarn))
            Notify.show("注意: 这份蓝图没写出资产路径（跨存档会缺件，看日志）",
                "capture: mesh_path missing", "error")
        end
    end

    -- ★ 屏幕提示（待办 1）: 采集完立刻给一行"看得见"的结果。
    --   放在这里而不是函数最后 —— 后面的网格注册表导出要跑几秒，
    --   玩家不该为了看到"采集成功"等那么久。
    local n_types = 0
    if type(bp.stats) == "table" and type(bp.stats.types) == "table" then
        for _ in pairs(bp.stats.types) do n_types = n_types + 1 end
    end
    Notify.show(string.format("采集完成: %d 件 / %d 类型 -> %s",
        #bp.buildings, n_types, final_name),
        string.format("capture done: %d buildings, %d types", #bp.buildings, n_types))

    -- 采集完顺手做两件只读的事:
    --   1. 刷新静态网格注册表
    --   2. 把"注册表 + 每个类型的自动匹配结果"导出成 pwpr_meshes.txt
    -- 后者是补齐【结构件网格映射】的关键材料:
    -- 结构件在 actor 上读不到 mesh，只能靠名字匹配，而匹配是否靠谱
    -- 要看真实资产名长什么样。这个文件就是真实资产名清单。
    local mesh_note = "网格注册表: 未建立"
    pcall(function()
        MeshMap.load_overrides(Util.script_dir)
        local n = MeshMap.build_registry(true)
        local types = Capture.type_table(records)
        local resolved = 0
        for i = 1, #types do
            if MeshMap.resolve({ t = types[i].t, mesh = types[i].mesh }) ~= nil then
                resolved = resolved + 1
            end
        end
        local lines = MeshMap.discovery_lines(types)
        -- ★ 第 3 节: 逐类型的网格读取诊断（含"朝向差"列）。
        --   2026-09-26 深夜发现: 这个报告写了但【从来没被调用过】 ——
        --   所以 pwpr_meshes.txt 里一直缺第 3 节，想查"为什么这件读不到网格"
        --   时没东西可看。写出来的诊断必须真的接上。
        local diag_lines = Capture.mesh_diag_lines()
        for i = 1, #diag_lines do lines[#lines + 1] = diag_lines[i] end
        -- 第 4 节: 材质清单（挑投影材质用）
        local mat_lines = MeshMap.material_dump_lines(200)
        for i = 1, #mat_lines do lines[#lines + 1] = mat_lines[i] end
        -- 第 5 节: ★★ 从网格组件反查【建筑类型 -> 网格】
        --   这是"找不到资产名"的终极手段: 建筑既然画出来了，就一定有个网格
        --   组件在画它，而组件全名里就写着宿主建筑的类型名。
        --   不依赖 obj.Mesh，也不靠猜名字。
        local cm_lines = MeshMap.component_mesh_lines(200)
        for i = 1, #cm_lines do lines[#lines + 1] = cm_lines[i] end
        -- 第 6 节: 实例化组件实际在用的网格（结构件/作物靠 HISM 画）
        local ism_lines = MeshMap.ism_dump_lines(300)
        for i = 1, #ism_lines do lines[#lines + 1] = ism_lines[i] end
        local mpath = Util.join(Util.script_dir, "pwpr_meshes.txt")
        Util.write_file(mpath, table.concat(lines, "\r\n") .. "\r\n", true)
        mesh_note = string.format(
            "网格: 注册表 %s 个, 类型可解析 %d/%d   -> %s",
            tostring(n), resolved, #types, mpath)
        Log.emit(mesh_note)
        Log.emit(MeshMap.stats_line())
    end)
    if mesh_note == "网格注册表: 未建立" then
        Log.emit("!! " .. mesh_note)
    end

    -- ★★★ 2026-09-28 修（玩家反馈确认）: 采集那条提示是**【导出之前】发的**
    --   （见上面第 356 行"采集完成"），而导出（刷新网格注册表 + 写 pwpr_meshes.txt）
    --   会卡住游戏主线程几秒 —— 卡住期间**没有画面**，但 `hud_seconds` 的计时在走
    --   ⇒ 导出超过 hud_seconds 时，提示会"刚出现就被收走"。
    --   修法: 导出结束后把**最后一条提示重发一次**（`Notify.resend` 会绕过节流、
    --   重新计时；开销约 60ms 的 SetText）——
    --   既保留"采集完立刻有反馈"的好处，又能在卡顿结束后完整停留 hud_seconds。
    pcall(function() Notify.resend() end)

    Log.emit("")
    Log.emit("下一步: 按 J 加载这张蓝图 -> 按 N 做一次能力探测 -> 按 K 放投影")

    -- 顺便更新一下库列表
    pcall(function() Library.refresh() end)
    flush_log()
end

-- ---------------------------------------------------------------------------
-- S2 蓝图库
-- ---------------------------------------------------------------------------

--- `Y` 的实际回调: 采集。半径由 `capture_radius_m` 决定。
---
--- ★ 2026-09-29 玩家要求合并成**一个采集键**:
---   原话「我之前采集的时候看你提示是说 Y 或 U，保留一个采集键就好了」——
---   以前是 `Y` = 玩家附近、`U` = 全部建筑两个键；现在只留 `Y`，
---   想采全部就把 `capture_radius_m` 设成 `0`（详见配置说明）。
---   顺带把空出来的 `U` 给了"建筑吸附"（它需要一个小键盘之外、实测空闲的键）。
local function do_capture_key()
    local r = tonumber(Config.get("capture_radius_m")) or 150
    if r <= 0 then
        do_capture("all")
    else
        do_capture("sphere")
    end
end

local function do_library_next()
    Log.clear()
    Log.section("蓝图库")

    local n, note = Library.refresh()
    Log.emit(string.format("库: %d 张    %s", n, tostring(note)))
    if n == 0 then
        Log.emit("库是空的。先按 Y 采集一个基地。")
        Notify.show("蓝图库是空的 —— 先按 Y 采集一个基地", "library empty", "error")
        flush_log()
        return
    end

    local entry = Library.next_entry()
    if entry == nil then
        Log.emit("没有可取的下一条。")
        Notify.show("蓝图库: 没有可取的下一条", "library: no next entry", "error")
        flush_log()
        return
    end

    local bp, lerr, okv, errors, warnings = Library.load(entry.file)
    if bp == nil then
        Log.emit("!! 加载 " .. tostring(entry.file) .. " 失败: " .. tostring(lerr))
        Notify.show("加载蓝图失败: " .. tostring(entry.file), "load failed", "error")
        flush_log()
        return
    end

    Log.emit("选中: " .. tostring(entry.file))
    if not okv then
        Log.emit(string.format("!! 校验未通过（%d 个错误），仍可预览:", #errors))
        for i = 1, math.min(#errors, 6) do Log.emit("   " .. errors[i]) end
    end
    if #warnings > 0 then
        Log.emit(string.format("警告 %d 条", #warnings))
        for i = 1, math.min(#warnings, 5) do Log.emit("   " .. warnings[i]) end
    end

    Session.activate(bp, entry.file)
    emit_lines(BP.summary_lines(bp, 8))

    -- 蓝图的层高可能和 config 不同，同步到会话
    Session.rot_step = tonumber(Config.get("rotate_step_deg")) or 15.0
    Session.step_cm = tonumber(Config.get("nudge_step_cm")) or 100

    Log.emit("")
    Log.emit("已加载。按 K 放投影（会先做门禁检查）。")
    Log.emit("再按一次 J 可以切到下一张。")

    -- ★ 屏幕提示: 一行讲清"现在加载的是哪张、多少件、第几张"
    local n_types = 0
    if type(bp.stats) == "table" and type(bp.stats.types) == "table" then
        for _ in pairs(bp.stats.types) do n_types = n_types + 1 end
    end
    Notify.show(string.format("已加载蓝图 %s: %d 件 / %d 类型（库共 %d 张，按 K 放投影）",
        tostring(entry.file), #bp.buildings, n_types, n),
        string.format("loaded %s: %d buildings", tostring(entry.file), #bp.buildings))
    flush_log()
end

-- ---------------------------------------------------------------------------
-- S3 能力探测
-- ---------------------------------------------------------------------------

local function do_probe()
    Log.clear()
    Log.emit("开始能力探测。全过程会逐步写入 pwpr_probe.txt。")
    Log.emit("如果游戏崩了，请把那个文件发出来 —— 最后一条 START 就是崩溃点。")

    local ready, missing = Probe.run(Util.script_dir, {
        max_step = tonumber(Config.get("probe_max_step")) or 0,
    })

    Log.emit("")
    Log.emit("==================================================")
    if ready then
        -- ★★★ 2026-09-28 玩家反馈后改: 探测通过就**直接帮玩家打开**投影开关。
        --
        -- 为什么必须自动开（原来的做法是错的）:
        --   配置文件的规则是"**只写和默认值不同**的键"，而 `ghost_enabled` 默认就是 false
        --   ⇒ 文件里**根本没有这一行**。结果提示语让玩家"把 ghost_enabled 改成 true"
        --   —— 他打开 pwpr_config.json 找不到这个键，只能猜着加一行（玩家实测反馈）。
        --   ⇒ 探测通过本来就是"该开门"的信号，这里直接 set + save，
        --     那一行就会**带着 true 出现在配置文件里**（想关掉随时改回 false）。
        local prev = Config.get("ghost_enabled")
        Config.set("ghost_enabled", true)
        local sok, serr = Config.save()
        if sok then
            Log.emit("能力探测通过 —— 投影渲染已解锁，并已自动写入 ghost_enabled = true。")
            Log.emit(string.format("（原来是 %s；想关掉就把 pwpr_config.json 里的 "
                .. "ghost_enabled 改回 false 再按 F8）", tostring(prev)))
            Notify.show("投影已解锁（已自动开启），按 K 放置投影",
                "probe OK: ghost enabled automatically")
        else
            -- 写配置失败极少见（磁盘只读等），这时才退回"手动加一行"的说法
            Log.emit("!! 能力探测通过，但自动写配置失败: " .. tostring(serr))
            Log.emit("   请手动在 pwpr_config.json 里加一行: \"ghost_enabled\": true")
            Notify.show("投影已解锁，但自动保存配置失败（看日志）",
                "probe OK: auto-enable failed", "error")
        end
    else
        Log.emit("能力探测未全部通过。缺少: " .. table.concat(missing, ", "))
        Log.emit("请把 pwpr_probe.txt 发出来。")
        Notify.show("能力探测未通过: 缺 " .. table.concat(missing, ", "),
            "probe failed: " .. table.concat(missing, ", "), "error")
    end
    Log.emit("==================================================")
    flush_log()
end

-- ---------------------------------------------------------------------------
-- S9 屏幕提示通道探测（按 O）
--
-- 和 S3（按 N）分开的原因:
--   S3 会创建/销毁引擎对象（spawn host / ISM / 材质），是"投影能不能画"的门禁。
--   S9 只是**读**（拿 PlayerController、枚举函数名和参数签名、构造 FText），
--   用来回答"屏幕上能不能出字"。两件事不该互相绑架。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 收回屏幕提示控件（小键盘 1）—— ★ 紧急出口
--
-- 为什么需要: 2026-09-27 出过一次严重事故 —— 我们自建的提示控件用了
-- SetVisibility(0)（= 吃输入），结果把游戏 Esc 菜单的鼠标点击全吃掉，
-- 玩家连"返回标题"都点不了，只能 Alt+F4。
-- 根因已修（现在一律用 3 = HitTestInvisible，渲染但不吃输入），
-- 但**这种"盖在游戏 UI 上的东西"必须留一个一键收回的出口**。
-- ---------------------------------------------------------------------------

local function do_drop_notify_widget()
    local ok = Hud.destroy_own_widget()
    Log.clear()
    if ok then
        Log.emit("已收回屏幕提示控件（从视口移除）。")
    else
        Log.emit("当前没有我们自己的提示控件（不需要收回）。")
    end
    emit_lines(Hud.status_lines())
    flush_log()
    Notify.show(ok and "已收回提示控件" or "当前没有提示控件",
        "notify widget removed")
end

local function do_probe_ui()
    Log.clear()
    Log.section("屏幕提示通道探测（S9）")
    -- ★ 注意: 字符串里不要写英文双引号（会直接把 Lua 字符串截断）
    Log.emit("目的: 找出「把一行字显示在画面上」的可用通道。")
    Log.emit("背景: PrintString 会崩游戏（已实测），所以必须另找路径。")
    Log.emit("做法: 先枚举 PlayerController 的函数名和参数签名 —— 不猜。")
    Log.emit("结果写: " .. Util.join(Util.script_dir, Probe.UI_FILE))
    Log.emit("")

    local ok, detail = Probe.run_ui(Util.script_dir)

    Log.emit("")
    Log.emit("==================================================")
    if ok then
        Log.emit("S9 跑完了。")
    else
        Log.emit("S9 有步骤失败（不影响游戏功能）。")
    end
    Log.emit("最后一条: " .. tostring(detail))
    Log.emit("把 " .. Probe.UI_FILE .. " 整个发出来，就能确定用哪条通道。")
    Log.emit("==================================================")
    emit_lines(Hud.status_lines())
    flush_log()

    Notify.show("提示通道探测完成（详情见 " .. Probe.UI_FILE .. "）",
        "notify probe done")
end

-- ---------------------------------------------------------------------------
-- S4 投影
-- ---------------------------------------------------------------------------

--- refresh_projection(reason, rebuild)
---   rebuild = false : 只是"挪动/旋转"，局部实例模式下改组件变换就够了
---   rebuild = true  : 显示内容变了（换层），必须重灌实例
-- ---------------------------------------------------------------------------
-- ★★ "已经放上去的那一件，投影就不再画"（玩家 2026-09-29 要求）
--
--   不这么做的话: 实物和投影蓝色网格重合 ⇒ 深度争夺 ⇒ 彩色/蓝色交替闪。
--   机制、安全约定见 `pwpr_placed.lua` 的文件头。
--
--   ⚠️ 这三个是**前向声明**: 它们互相引用（放下一件 ⇒ 重灌 ⇒ 又可能放下一件），
--      所以先声明再赋值。**千万不要**在下面再写一次 `local function 同名` ——
--      那会遮蔽外层的（踩坑记录 §43），赋值全落空。
-- ---------------------------------------------------------------------------
local placed_rebuild_pending = false
local placed_watch_on = false
local start_placed_watch, refresh_projection

--- 重灌投影之前调一次: 算出"哪些记录已经有实物了" ⇒ 写进 Ghost.skip
--- 返回: 隐藏件数（失败或没开这个功能时返回 0）
local function apply_placed_mask(reason)
    local n = 0
    -- ★★★ 2026-09-29 第二次崩溃后: **枚举关卡建筑**这条路默认关闭
    --   （`level.Actors` 会保留已摧毁的 actor ⇒ 读它就是原生访问违例；
    --    而且死对象还占着记录位置 ⇒ "拆掉恢复"永远不生效）。
    --   见 pwpr_config.lua 里 ghost_hide_enum 的说明。
    local enum_on = false
    pcall(function()
        enum_on = (Config.get("ghost_hide_enum") == true)
    end)
    if not enum_on then
        Ghost.skip = nil      -- 清空"已放上的"名单: 重新放投影会把所有件都画出来
        return 0
    end
    Ghost.skip = nil
    local ok, a = pcall(function()
        return Placed.refresh(Session.bp, Session.place())
    end)
    if ok and a ~= nil then
        Ghost.skip = Placed.hidden
        n = a
    end
    if n > 0 then
        Log.emit(string.format(
            "  [placed] %s: 有 %d 件已经放上去了 ⇒ 这些**不再画**（拆掉会自动恢复）",
            tostring(reason), n))
    end
    return n
end

--- ★ 刚放下一件时（玩家 2026-09-29 提的方案，已实现）: **只入队，不立刻隐藏**。
---
---   为什么（两个实测问题一起解决）:
---     ① **卡顿**: 原来每放一件都要重灌一次投影（哪怕是增量的）；
---        现在连放 20 块只在**停下来之后**重灌一次；
---     ② **偶尔漏一块**: 放得快的时候，几个"待确认"会互相覆盖，
---        偶尔有一块没被处理。现在每条记录**只入队一次**，谁也不会丢。
---   代价: 连放期间那些件**暂时还会闪**，等停下来（默认 3 秒）才一起消失 ——
---   玩家明确认可这个取舍（配置 `ghost_hide_placed_batch_s`，设 0 = 立刻处理）。
local placed_batch_gen = 0

--- 清算: 把"这期间放上的"一次性从投影里去掉（只重灌受影响的组）
local function flush_placed_batch(reason)
    local list = Placed.take_pending()
    if #list == 0 then return 0 end
    local n, why = Ghost.rehide(list)
    if n == nil then
        -- ★ 把"为什么没用增量路"写出来 —— 否则只会看到"卡一下然后重灌"，
        --   完全不知道是门槛拒了（2026-09-29 就是这么绕了一圈）。
        Log.emit(string.format(
            "  [placed] 增量重灌不可用（%s）⇒ 退回完整重灌（会慢一点）",
            tostring(why)))
        refresh_projection("放上了 " .. tostring(#list) .. " 件", true)
        return #list
    end
    Placed.last_src = string.format("批量隐藏 %d 件（只重灌 %d 个组件）",
        #list, n)
    Log.emit(string.format(
        "  [placed] %s ⇒ 把这期间放上的 %d 件一起从投影里去掉"
        .. "（只重灌 %d 个组件，没重灌整个投影）",
        tostring(reason), #list, n))
    if Notify ~= nil then
        Notify.show(string.format("投影已更新: 这期间放上的 %d 件不再画", #list),
            string.format("ghost updated: %d placed hidden", #list))
    end
    return #list
end

local function on_ghost_placing(rec_idx)
    if not Ghost.visible or rec_idx == nil then return end
    local added = Placed.hide_now(rec_idx)
    if added then
        Log.line(string.format(
            "  [placed] 记录 #%d 已放上 ⇒ 入队（待处理 %d 件；等停下来一起从投影里去掉）",
            rec_idx, Placed.pending_count()))
    end
    -- ★ 尾部防抖: 每来一件就把"清算时刻"往后推；真正停下来才清算。
    local batch_s = 3.0
    pcall(function()
        local v = require("pwpr_config").get("ghost_hide_placed_batch_s")
        if tonumber(v) ~= nil then batch_s = tonumber(v) end
    end)
    if batch_s <= 0 then
        flush_placed_batch("批量已关闭")
        start_placed_watch()
        return
    end
    placed_batch_gen = placed_batch_gen + 1
    local my = placed_batch_gen
    -- ★ 看门狗同时启动: 它每 2.5 秒会检查"队列安静够久了没有"（兜底清算），
    --   所以就算下面这个延时回调丢了，清算也一定会发生。
    start_placed_watch()
    Sched.game_thread(function()
        if my ~= placed_batch_gen then return end     -- 期间又来新的了 ⇒ 这轮作废
        pcall(function()
            if Ghost.visible then
                flush_placed_batch(string.format("安静了 %.0f 秒", batch_s))
                start_placed_watch()
            end
        end)
    end, math.floor(batch_s * 1000))
end

--- 落地确认成功: 把 actor 句柄记下来（"拆掉检测"要用）
local function on_ghost_placed_confirmed(rec_idx, actor)
    if rec_idx == nil then return end
    Placed.stash_actor(rec_idx, actor)
end

--- 落地确认失败（游戏拒绝了这次放置）: 从待处理队列里去掉（不隐藏它）
local function on_ghost_placed_failed(rec_idx)
    if rec_idx == nil then return end
    if Placed.cancel_pending(rec_idx) then
        Log.line(string.format(
            "  [placed] 游戏没建出来 ⇒ 把记录 #%d 从待处理队列去掉（不隐藏它）",
            rec_idx))
    end
end

--- ★ 收到"新建筑出现"的通知 —— 这一版**什么都不做**（只留日志）。
---   为什么不在这里做事（2026-09-29 两次实测的教训，§49/§50）:
---   ① 通知来得太早，那一刻 actor 的位置/类型还没填好；
---   ② "该藏哪一条"我们**已经有更可靠的信息**（吸附时就知道 rec_idx）
---      ⇒ 由 `on_ghost_placing` / `on_ghost_placed_confirmed` 负责。
local function on_ghost_new_object(_obj)
    return
end

--- ★ 每隔几秒看一眼"我们藏起来的那几件的实物还在不在"（拆掉 ⇒ 恢复渲染）。
---   两条腿走路（2026-09-29 玩家实测"拆了没效果"之后补的）:
---     ① 快路径: `Util.valid` 检查引用（便宜，拆了 2.5 秒内就恢复）；
---     ② 慢路径: **每 3 次 tick 做一次全扫**（约 7.5 秒），用权威结果纠正 ——
---        因为游戏拆除不一定让 IsValid 立刻变 false（实测有时不灵），
---        而全扫很便宜（实测这个基地只读 677 个 actor）。
---   ★ 名单变了也**不重灌整个投影** —— 让 `Ghost.rehide` 只动受影响的组。
local placed_watch_tick_count = 0
local function placed_watch_tick()
    pcall(function()
        if not Ghost.visible then return end
        placed_watch_tick_count = placed_watch_tick_count + 1

        -- ★★ 自愈兜底（2026-09-29 玩家实测: "停了十几秒都没清算、也没提示"）:
        --   批量清算原来**只靠一个延时回调**。万一那个回调没跑到，
        --   待处理队列就会一直挂着、投影永远不更新。
        --   ⇒ 这里每 2.5 秒看一眼: 队列安静够久就直接清算 ——
        --     于是"清算"不再依赖任何单点。
        local batch_s = 3.0
        pcall(function()
            local v = require("pwpr_config").get("ghost_hide_placed_batch_s")
            if tonumber(v) ~= nil then batch_s = tonumber(v) end
        end)
        if batch_s > 0 and Placed.pending_count() > 0
            and Placed.pending_idle_s() >= batch_s then
            flush_placed_batch(string.format("兜底清算（队列安静了 %.1f 秒）",
                Placed.pending_idle_s()))
        end

        local changed = false
        -- ★★★ 2026-09-29 崩溃后的默认关闭: 这条"查引用还在不在"的快路径
        --   会对**已被摧毁的 actor** 调 `Util.valid()` —— 而 UE4SS 的这类调用
        --   一旦对象真死了就是**原生访问违例**（本次崩溃栈 44 帧全在 UE4SS 里，
        --   错误码 `EXCEPTION_ACCESS_VIOLATION reading 0xffff...ffff`）。
        --   **原生崩溃 pcall 抓不住**，所以唯一安全的做法是"别去碰"。
        --   而且它本来也不可靠（日志里一直报 `15 个引用，15 个存活`，
        --   而玩家明明已经拆了）。
        --   ⇒ 默认关闭，恢复完全交给**兜底全扫**（它是重新枚举活对象，天然安全）。
        --   想再试就 `ghost_hide_alive_check = true`。
        local alive_check = false
        pcall(function()
            alive_check = (require("pwpr_config").get("ghost_hide_alive_check") == true)
        end)
        local delta = nil
        if alive_check then delta = Placed.check_alive() end
        if delta ~= nil and #delta > 0 then
            changed = true
            Ghost.rehide(delta)
        end
        -- ★★ 兜底全扫改成**分片**（2026-09-29 玩家反馈"每次刷新都会卡顿"）:
        --   原来每个扫描周期都**一次性**读完整个关卡建筑列表（600+ 个 actor 的
        --   位置/类型/朝向全是跨边界调用）⇒ 那一帧必然卡一下。
        --   现在每个 tick 只读一小片（150 个），几帧扫完 ⇒ **单帧开销很小**，
        --   不再有可见的卡顿；而且只有"确实藏了东西"时才扫（没藏 = 零开销）。
        --   ★ 另外: 正在批量放置（队列非空）时**不扫** —— 别和放置抢那一帧。
        local scan_every = 3
        pcall(function()
            local v = require("pwpr_config").get("ghost_hide_scan_interval_s")
            if tonumber(v) ~= nil and tonumber(v) > 2.5 then
                scan_every = math.max(1, math.floor(tonumber(v) / 2.5))
            end
        end)
        local enum_on = false
        pcall(function()
            enum_on = (require("pwpr_config").get("ghost_hide_enum") == true)
        end)
        -- ★★ 周期性扫描还要**单独再过一个开关**（`ghost_hide_scan`，默认关）:
        --   它是两次崩溃的路线（就在玩家拆完建筑之后去读那个 pending-kill 对象）。
        local scan_on = false
        pcall(function()
            scan_on = (require("pwpr_config").get("ghost_hide_scan") == true)
        end)
        local scan_due = enum_on and scan_on
            and ((placed_watch_tick_count % scan_every) == 0)
        if (not changed) and scan_due and Placed.pending_count() == 0 then
            local sd, state = Placed.scan_step(150)
            if sd ~= nil and #sd > 0 then
                changed = true
                local n = Ghost.rehide(sd)
                if n == nil then
                    refresh_projection("有建筑被拆掉了", true)
                else
                    Log.emit(string.format(
                        "  [placed] 分片全扫发现名单变了 ⇒ 只重灌 %d 个组件（%d 条记录）",
                        n, #sd))
                end
            end
        end
        if changed then
            Notify.show("投影已跟着实际建筑更新（拆掉/新建）",
                "ghost sync (dismantle/build)")
        end
    end)
end

start_placed_watch = function()
    if placed_watch_on == true then return end
    placed_watch_on = true
    Sched.game_thread(function()
        placed_watch_on = false
        placed_watch_tick()
        -- 只有"还藏着东西"或"还有待处理的"时才继续排；否则停下来（不空转）
        if Ghost.visible
            and (Placed.count() > 0 or Placed.pending_count() > 0) then
            start_placed_watch()
        end
    end, 2500)
end

refresh_projection = function(reason, rebuild)
    if not Ghost.visible then return end
    local place = Session.place()
    if place == nil then
        Log.emit("!! 拿不到玩家位置，投影保持在原地")
        return
    end

    if rebuild ~= true and Ghost.instance_mode ~= "world" then
        -- 局部实例模式：移动投影只改组件变换，不必重建几千个实例
        --
        -- ★ 2026-09-27 排查 rotate 崩溃时加的细粒度标记:
        --   ">>" / "<<" 只框住整个按键处理函数，看不出崩在哪一步。
        --   拆成三段后，再崩就能直接定位到"引擎调用"还是"提示发送"。
        --   （去掉它们只影响日志长度，不影响功能）
        Log.emit("[step] apply_transform 开始")
        Log.flush()
        Ghost.apply_transform(place)
        Log.emit("[step] apply_transform 完成")
        Log.flush()
        Log.emit(string.format("投影已移动（%s）", reason))
        -- ★ 屏幕提示: 微调是"按一下要看一下"的操作，屏幕上必须给反馈。
        --   （方向键/小键盘是按键重复速率触发的，节流在 Notify 里做）
        Notify.show(string.format("投影 %s   偏移 %s", reason, Session.offset_note()),
            string.format("ghost %s  offset %s", reason, Session.offset_note()))
        Log.emit("[step] 提示已发送")
        Log.flush()
        return
    end

    local mode, idx = Session.filter()
    -- ★ 重灌前同步一次"已放上的不渲染"名单（玩家换层/刷新时也要保持准确）
    apply_placed_mask(reason)
    local okf, ferr = Ghost.fill(Session.bp, place, mode, idx)
    if not okf then
        Log.emit("!! 投影刷新失败: " .. tostring(ferr))
        Notify.show("投影刷新失败: " .. tostring(ferr), "ghost refresh failed", "error")
        return
    end
    Log.emit(string.format("投影已刷新（%s）: %s", reason, Ghost.describe()))
    Notify.show(string.format("投影已刷新（%s）: %d 件", reason, Ghost.stats.instances or 0),
        string.format("ghost refreshed (%s)", reason))
end

local function do_ghost_toggle()
    Log.clear()
    Log.section("投影")

    if Ghost.visible then
        -- ★★ 这里**不需要**再判断"世界有没有换":
        --   换地图时 LoadMapPre 钩子已经 `Ghost.forget`（visible=false、引用清空），
        --   所以"世界变了还显示着旧投影"这种情况不会出现。
        --   历史上这里曾用"世界标记"判断 —— 而那个标记会抖动，结果是:
        --   玩家想按 K 收起，却因为误判"换了世界"把投影**重新放了一遍**。
        Ghost.clear()
        Log.emit("投影已收起，宿主对象已销毁（不会在读档时留下残留）。")
        Notify.show("投影已收起（宿主对象已销毁）", "ghost hidden", "error")
        flush_log()
        return
    end

    if not Session.active or Session.bp == nil then
        Log.emit("!! 还没有加载蓝图。先按 Y 采集，再按 J 加载。")
        Notify.show("还没有加载蓝图: 先按 Y 采集，再按 J 加载", "no blueprint loaded", "error")
        flush_log()
        return
    end

    local okp, perr = Ghost.prepare(Config)
    if not okp then
        Log.emit("!! 无法开始投影: " .. tostring(perr))
        Log.emit("")
        Log.emit("投影渲染需要先通过能力探测（阶段 S3）。步骤:")
        Log.emit("  1) 站进世界，等画面稳定")
        Log.emit("  2) 按 N 跑探测 —— **通过后会自动打开投影开关**（写入 ghost_enabled = true）")
        Log.emit("  3) 再按 K 就能放投影")
        Log.emit("")
        Log.emit("（如果探测通过但这里仍然锁着，说明你自己把 ghost_enabled 设成了 false：")
        Log.emit("  要么在 " .. tostring(Config.path) .. " 里删掉那一行（= 用默认值），")
        Log.emit("  要么改成 true，然后按 F8 重载。）")
        Notify.show("投影没解锁: 先按 N 做能力探测（通过后会自动开启）",
            "ghost locked: run probe (N); it auto-enables", "error")
        flush_log()
        return
    end

    local place = Session.place()
    if place == nil then
        Log.emit("!! 拿不到玩家位置，无法定位投影。")
        Notify.show("拿不到你的位置，无法定位投影", "cannot locate ghost: no player position", "error")
        flush_log()
        return
    end

    local mode, idx = Session.filter()
    -- ★★ 重灌之前先算"哪些已经放上去了"（放上的就不画了，见 pwpr_placed.lua）
    local n_placed = apply_placed_mask("按 K 放投影")
    local okf, ferr = Ghost.fill(Session.bp, place, mode, idx)
    if not okf then
        Log.emit("!! 投影构建失败: " .. tostring(ferr))
        Notify.show("投影构建失败: " .. tostring(ferr), "ghost build failed", "error")
        Ghost.clear()
        flush_log()
        return
    end

    Log.emit("投影已放置。")
    emit_lines(Session.status_lines())
    Log.emit("  " .. Ghost.describe())
    Log.emit("  材质: " .. Ghost.material_description())
    Log.emit("  脚底偏移: " .. Session.feet_note())
    -- 材质回读: "材质到底有没有真的设上去"的硬证据。
    -- 如果没有这一行/显示回读失败，说明画出来会是 UE 的灰白网格材质。
    local rb = Ghost.material_readback()
    Log.emit("  材质回读(槽0): " .. tostring(rb or "(没记录)"))
    Log.emit("  换材质: 小键盘 *")
    if Ghost.stats.skipped_no_mesh > 0 then
        Log.emit(string.format(
            "  注意: %d 件没有解析到网格资产，未显示（多为结构件）。",
            Ghost.stats.skipped_no_mesh))
        -- ★ 列出"是哪些类型"（按件数降序，最多 10 行）——
        --   换存档投影时如果缺件，这里能直接告诉你缺的是谁、要补哪条映射。
        local tn = Ghost.stats.no_mesh_by_type
        if type(tn) == "table" then
            local arr = {}
            for k, v in pairs(tn) do arr[#arr + 1] = { k = k, n = v } end
            table.sort(arr, function(a, b)
                if a.n ~= b.n then return a.n > b.n end
                return a.k < b.k
            end)
            for i = 1, math.min(#arr, 10) do
                Log.emit(string.format("    缺网格: %-32s %d 件", arr[i].k, arr[i].n))
            end
            if #arr > 10 then
                Log.emit(string.format("    …还有 %d 种类型也缺", #arr - 10))
            end
        end
        Log.emit("  按 Y 重新采集一次，会同时导出 pwpr_meshes.txt")
        Log.emit("  （里面是真实的网格资产名，可据此补 pwpr_meshmap.json）")
    end
    Log.emit("")
    Log.emit("微调: 方向键（F9 切 移动/旋转/材质）  小键盘 8/2 4/6 9/3 挪  +/- 旋转  5 复位  0 换步长")
    Log.emit("分层: L      对齐到原建筑: U（放下时已自动吸）      重新定位到脚下: H      收起: 再按 K")

    -- ★ 屏幕提示: 放下投影先立刻给一行（别让玩家在自动对齐那一两秒里干等），
    --   吸附完成后**再发一行**（用 show_force 忽略节流 —— 见下面的包装函数）。
    Notify.show(string.format("投影已放置: %d 件   材质 %s",
        Ghost.stats.instances or 0,
        tostring(MATERIAL_CN[Ghost.material_mode] or Ghost.material_mode)),
        string.format("ghost placed: %d instances", Ghost.stats.instances or 0))
    flush_log()
end

local function do_layer_cycle()
    if not Session.active then
        Log.clear()
        Log.emit("还没有加载蓝图。")
        Notify.show("还没有加载蓝图（先按 J）", "no blueprint loaded", "error")
        flush_log()
        return
    end
    Session.cycle_layer()
    Log.clear()
    Log.emit("分层: " .. Session.layer_label())
    local fmode, fidx = Session.filter()
    local picked = BP.select_indices(Session.bp, fmode or "all", fidx, nil, nil)
    Log.emit(string.format("该分层包含 %d 件建筑", #picked))
    if Ghost.visible then
        -- 换层改变了"显示哪些件"，必须重灌实例
        refresh_projection("换层", true)
    else
        Log.emit("（投影当前是收起的，按 K 放置后即可看到）")
    end
    Notify.show(string.format("分层: %s   %d 件", Session.layer_label(), #picked),
        string.format("layer: %s  %d buildings", Session.layer_label(), #picked))
    flush_log()
end

local function do_resnap()
    if not Session.active then
        Log.clear()
        Log.emit("还没有加载蓝图。")
        Notify.show("还没有加载蓝图（先按 J）", "no blueprint loaded", "error")
        flush_log()
        return
    end
    local okr, rerr = Session.resnap()
    Log.clear()
    if not okr then
        Log.emit("!! " .. tostring(rerr))
        Notify.show("重新吸附失败: " .. tostring(rerr), "re-snap failed", "error")
        flush_log()
        return
    end
    Log.emit("已重新吸附到你的当前位置，偏移与旋转清零。")
    if Ghost.visible then refresh_projection("重新吸附") end
    Notify.show("已重新吸附到你当前位置（偏移与旋转清零）", "re-snapped to player")
    flush_log()
end

-- ---------------------------------------------------------------------------
-- 建筑吸附（路线图"待办 2"）—— 放下投影时**自动吸**，另有一个手动键
--
-- ★ 为什么是"放下时就吸"（玩家 2026-09-29 明确要求）:
--   原话: "我预期应该是在准备放置的时候吸附上去。"
--   ⇒ 按 K 把投影放下的那一刻就对齐到原建筑，不用再按一个键。
--   ⇒ 手动键（默认 `U`）留给"后来挪过、想再对齐一次"的情况。
--
-- ★ 为什么**不**在"挪投影"时自动吸:
--   ① 方向键/小键盘是**按键重复速率**触发的，按住一秒能来十几次，
--      而吸一次要读几千个 actor 的位置 ⇒ 每按一下卡一下，根本没法精调；
--   ② 它会和手动微调**互相打架**（你刚挪开一格就被吸回去）。
--   对齐之后偏移会一直保留（走动不影响投影），所以"调好再微调"是安全的。
--
-- ★ 与 H 的区别（两个"吸附"很容易混）:
--   H（resnap） = 把投影**挪到你脚下**，偏移清零（定位用）
--   U/自动吸   = 把投影**对齐到附近的真实建筑**（对齐用，改偏移和朝向）
-- ---------------------------------------------------------------------------

--- 求解 + 应用 + 汇报一次吸附。
--- quiet = true: 自动吸附用 —— 失败只写日志（在空地上放投影吸不了很正常，
---              不该弹一个红色错误把玩家吓一跳）。
--- 返回 是否成功（boolean）
local function snap_run(quiet)
    -- ---- 前置条件（不满足不是"错误"，只是这次不吸）----------------------
    local skip = nil
    if Config.get("snap_enabled") ~= true then
        skip = "吸附已在配置里关闭（snap_enabled = false）"
    elseif not Session.active or Session.bp == nil then
        skip = "还没有加载蓝图"
    elseif not Ghost.visible then
        skip = "投影是收起的"
    end
    if skip ~= nil then
        Log.emit("!! 吸附跳过: " .. skip)
        if not quiet then
            Notify.show("吸附跳过: " .. skip, "snap skipped", "error")
        end
        return false
    end

    local place0 = Session.place()
    if place0 == nil then
        Log.emit("!! 拿不到玩家位置，无法计算吸附。")
        if not quiet then
            Notify.show("拿不到你的位置，无法吸附",
                "cannot snap: no player position", "error")
        end
        return false
    end

    Log.emit(string.format("基准: 投影原点 (%.0f, %.0f, %.0f) 朝向 %.1f 度",
        place0.x, place0.y, place0.z, place0.yaw or 0.0))
    Log.emit(string.format(
        "参数: 配对阈值 %.0f 厘米 / 复核容差 %.0f 厘米 / 至少对上 %d 件 / 找朝向 %s",
        tonumber(Config.get("snap_radius_cm")) or 0,
        tonumber(Config.get("snap_verify_cm")) or 0,
        tonumber(Config.get("snap_min_matches")) or 0,
        tostring(Config.get("snap_yaw_search") == true)))
    Log.flush()

    local t0 = os.clock()
    local res, err = Snap.solve(Session.bp, place0, {
        radius_cm   = Config.get("snap_radius_cm"),
        verify_cm   = Config.get("snap_verify_cm"),
        min_matches = Config.get("snap_min_matches"),
        yaw_search  = Config.get("snap_yaw_search") == true,
    })
    local ms = (os.clock() - t0) * 1000.0

    if res == nil then
        Log.emit("!! 吸附失败: " .. tostring(err))
        Log.emit(string.format("  （用时 %.0f 毫秒；投影一动没动，偏移和朝向都没改）", ms))
        Log.emit("  可以试: ① 站到基地里更靠中心的位置再按；")
        Log.emit("          ② 把 snap_radius_cm 调大（你离基地中心越远，需要的值越大）；")
        Log.emit("          ③ 用方向键/+- 把朝向转到大致对（差得太多时同类型的件配不上）；")
        Log.emit("          ④ 这张蓝图不是从这个基地采的（那就没有'原建筑'可对）。")
        if quiet then
            Log.emit("  （这是放下投影时的自动对齐 —— 附近没有可对齐的原建筑，"
                .. "投影留在你脚下，按 K 后自己挪即可）")
        else
            Notify.show("吸附失败: " .. tostring(err), "snap failed", "error")
        end
        return false
    end

    -- ★ 只改投影的偏移与朝向 —— **蓝图数据一个字节都不动**。
    --   反推: place = 锚点 + 偏移 + 脚底修正，所以反过来只需要一个增量:
    --         offset = offset + (place_new - place_old)
    --   （这样也就不需要知道脚底偏移 / 包围盒半高是多少。）
    Session.offset.x = Session.offset.x + (res.place.x - place0.x)
    Session.offset.y = Session.offset.y + (res.place.y - place0.y)
    Session.offset.z = Session.offset.z + (res.place.z - place0.z)
    Session.yaw = res.yaw_after

    emit_lines(Snap.report_lines(res))
    Log.emit(string.format("  用时 %.0f 毫秒", ms))

    -- ★ 这里**故意不调用 refresh_projection()**:
    --   它会再发一条屏幕提示，而 Notify 有 0.25 秒节流窗口 ——
    --   两条挤在一起时，**后发的那条（吸附结果）会被丢掉**，
    --   玩家就看不到"到底对上了多少件"。所以自己改、提示只发一条。
    local p2 = Session.place()
    if p2 ~= nil then
        if Ghost.instance_mode == "world" then
            -- ★ 世界空间实例（能力探测发现 AddInstance 不可用时的退路）里，
            --   实例坐标是**绝对世界坐标**，改组件变换完全无效 ⇒ 必须重灌。
            local fmode, fidx = Session.filter()
            apply_placed_mask("按吸附结果重建")
            Ghost.fill(Session.bp, p2, fmode, fidx)
            Log.emit("  投影已按吸附结果重建（世界空间实例模式必须重灌）。")
        else
            Ghost.apply_transform(p2)
            Log.emit("  投影已按吸附结果移动（局部实例模式，没有重建实例）。")
        end
    end

    local warn = ""
    if res.ambiguous then
        warn = "（有歧义，看一眼）"
    elseif res.low_coverage then
        warn = string.format("（匹配 %.0f%%，看一眼）", (res.ratio or 0.0) * 100.0)
    end
    Notify.show_force(string.format("吸附: 对上 %d/%d 件，移动 %.0f 厘米%s%s",
        res.matched, res.total or res.records or 0, res.shift_cm or 0.0,
        (math.abs(res.yaw_delta or 0.0) >= 0.5)
            and string.format("，转向 %+.0f°", res.yaw_delta) or "", warn),
        string.format("snap: %d/%d matched, moved %.0f cm",
            res.matched, res.total or res.records or 0, res.shift_cm or 0.0))
    return true
end

--- 手动吸附键（默认 `U`）
local function do_snap()
    Log.clear()
    Log.section("建筑吸附（手动）")
    snap_run(false)
    flush_log()
end

--- `K` 的实际回调: 放下投影 → **自动对齐一次**。
---
--- ★ 为什么把"自动对齐"放在这个包装里，而不是塞进 do_ghost_toggle:
---   do_ghost_toggle 定义在"建筑吸附"这一节**之前**，里面直接调 snap_run
---   会解析成全局变量（nil）⇒ 运行时 "attempt to call a nil value"
---   （这个坑本项目踩过，见 docs\踩坑记录.md §13）。
---
--- ★ 提示是**两条**: do_ghost_toggle 里先报"投影已放置"（立刻有反馈），
---   吸附算完（要读几千个 actor，通常 1 秒上下）再由 snap_run 报
---   "对上 N/M 件" —— 那条用 show_force 忽略节流，保证不会被前一条吃掉。
local function do_ghost_toggle_key()
    do_ghost_toggle()
    if not Ghost.visible then return end      -- 这次是按了"收起"，它自己已经报过了
    if Config.get("snap_on_place") == true then
        Log.emit("")
        Log.emit("—— 放下投影后的自动对齐（snap_on_place = true，可在配置里关掉）——")
        snap_run(true)
    end
    flush_log()
end

local function do_nudge(axis)
    if not Session.active then return end
    if not Ghost.visible then
        Log.clear()
        Log.emit("投影是收起的（按 K 放置后再微调）。")
        Notify.show("投影是收起的（按 K 放置后再微调）", "ghost hidden", "error")
        flush_log()
        return
    end
    Session.nudge(axis)
    refresh_projection("微调 " .. axis)
    Log.flush()
end

local function do_rotate(sign)
    if not Session.active then return end
    if not Ghost.visible then
        Log.clear()
        Log.emit("投影是收起的（按 K 放置后再旋转）。")
        Notify.show("投影是收起的（按 K 放置后再旋转）", "ghost hidden", "error")
        flush_log()
        return
    end
    Session.rotate(sign)
    refresh_projection("旋转")
    Log.flush()
end

local function do_step_cycle()
    local s = Session.next_step()
    Log.clear()
    Log.emit(string.format("微调步长 -> %d 厘米", s))
    Notify.show(string.format("微调步长 -> %d 厘米", s),
        string.format("step = %d cm", s))
    flush_log()
end

--- 偏移与旋转清零（NUM_5 / Ctrl+↑ 都用它）
local function do_reset_offset()
    Session.reset_offset()
    Log.clear()
    Log.emit("偏移与旋转已清零。")
    if Ghost.visible then
        local place = Session.place()
        if place ~= nil then Ghost.apply_transform(place) end
    end
    Notify.show("偏移与旋转已清零", "offset reset")
    flush_log()
end

-- ---------------------------------------------------------------------------
-- 帮助
-- ---------------------------------------------------------------------------

local function do_help()
    Log.clear()
    Log.line("=================== PWProjection 帮助 ===================")
    Log.line(string.format("构建标记: %s（改了功能就 +1；这一行能确认游戏里跑的是哪一版）",
        tostring(Util.BUILD)))
    Log.line("")
    -- ★ 按键一览改成从 Notify.KEYS 生成（单一来源）
    --   以前这些行是手写的双份文案，加了键就得记得改三处（帮助/控制台/文档）。
    --   现在加键只改 pwpr_notify.lua 里的 KEYS 一张表。
    emit_lines(Notify.key_lines())
    Log.line("")
    Log.line("投影材质（F9 进 material 模式，然后用 ← / → 切换）:")
    for i = 1, #Ghost.MATERIAL_MODES do
        local m = Ghost.MATERIAL_MODES[i]
        local mark = (m == Ghost.material_mode) and "  <- 当前" or ""
        Log.line(string.format("    %-10s %s%s", m,
            tostring(MATERIAL_CN[m] or "?"), mark))
    end
    Log.line("    （另有 " .. table.concat(Ghost.EXTRA_MATERIAL_MODES, " / ")
        .. " 可写进 config 的 ghost_material，不进循环）")
    Log.line("")
    Log.line("方向键 + 模式（不用修饰键，没有小键盘也能用）:")
    dual("  F9              切换方向键模式",
         "  F9            cycle arrow mode")
    dual("  当前模式: " .. tostring(PLACE_MODE_LABEL[place_mode] or place_mode),
         "  current mode = " .. tostring(place_mode))
    Log.line("")
    Log.line("    move      ↑前 ↓后 ←左 →右")
    Log.line("    rotate    ←逆时针 →顺时针 ↑抬高 ↓降低")
    Log.line("    material  ←→换材质  ↑换分层  ↓换步长")
    Log.line("")
    Log.line("  为什么不用修饰键组合: UE4SS 的按键绑定【不看修饰键】，")
    Log.line("  所以 Alt+↑ 会同时触发 Alt+↑ 和 ↑ 两件事。")
    Log.line("  而且 Ctrl 是游戏自己的闪避、Shift 是冲刺，都会附带动作。")
    Log.line("")
    Log.line(string.format("实际绑定成功 %d 个，失败 %d 个:",
        #bound, #failed))
    Log.line("  " .. table.concat(bound, ", "))
    if #failed > 0 then
        Log.line("  失败: " .. table.concat(failed, ", "))
    end
    Log.line("")
    Log.line("当前状态:")
    Log.line("  " .. Sched.describe())
    Log.line("  " .. MeshMap.stats_line())
    Log.line("  " .. Hud.describe())
    emit_lines(Session.status_lines())
    Log.line("  " .. Ghost.describe())
    -- ★ 建造吸附（钩子）: 一眼看出"钩子注册上没有、见过几次请求、吸上几件"
    emit_lines(BuildSnap.status_lines())
    Log.line("  " .. Placed.status_line())
    -- ★ 投影对齐（另一件事，按 U）: 把"上一次吸附算出了什么"留在这里
    Log.line("  投影对齐: " .. ((Snap.last ~= nil)
        and Snap.describe(Snap.last)
        or "还没用过（按 U；放下投影时的自动对齐默认已关）"))
    local gate_ok, gate_why = Ghost.check_gate(nil)
    Log.line(string.format("  投影门禁: %s (%s)", tostring(gate_ok), tostring(gate_why)))
    Log.line("")
    Log.line("屏幕提示（待办 1）:")
    emit_lines(Notify.status_lines())
    Log.line("  最近发到屏幕上的:")
    emit_lines(Hud.recent_lines())
    Log.line("")
    Log.line("配置: " .. tostring(Config.path))
    emit_lines(Config.brief_lines())
    if Config.multi_object_warn ~= nil then
        Log.line("  !! " .. tostring(Config.multi_object_warn))
    end
    Log.line("")
    Log.line("目录:")
    Log.line("  Scripts : " .. Util.script_dir)
    Log.line("  蓝图库  : " .. tostring(Library.dir))
    Log.line("  日志    : " .. tostring(Log.path_of("pwpr.log")))
    Log.line("  S9 报告 : " .. Util.join(Util.script_dir, Probe.UI_FILE))
    Log.line("========================================================")
    flush_log()

    -- 控制台再来一份纯 ASCII 的（中文在控制台会变成 ???）
    print(TAG .. " ---- PWPR keys ----")
    print(TAG .. " F7 help | F8 reload config")
    print(TAG .. " Y capture | J next bp | U snap-to-buildings")
    print(TAG .. " K ghost on/off | L layer | H resnap")
    print(TAG .. " N render-probe | O notify-probe")
    print(TAG .. " numpad 8/2 4/6 9/3 move, +/- rotate, 5 reset, 0 step")
    print(TAG .. " numpad 7 = snap ghost to nearby real buildings (snap_key)")
    print(TAG .. " numpad * = cycle ghost material")
    print(TAG .. " material mode: " .. Ghost.material_description())
    print(TAG .. " notify: " .. Util.ascii(Hud.describe()))
    print(TAG .. " ghost gate: " .. tostring(gate_ok) .. " (" .. Util.ascii(tostring(gate_why)) .. ")")
end

-- ---------------------------------------------------------------------------
-- 重载配置
--
-- 为什么需要它:
--   配置是启动时读一次的。而"探测通过后要把 ghost_enabled 改成 true"
--   这个动作如果必须重启游戏才生效，会白白多一轮往返。
--   所以给一个 F8：改完 pwpr_config.json 按一下，立刻重新读盘并生效。
--
-- 注意: 这个键【不会】绕过任何门禁 —— 它只是重新读文件。
--       ghost_enabled 仍然是用户手写进去的，能力探测结论仍然独立校验。
-- ---------------------------------------------------------------------------

local function do_reload_config()
    Log.clear()
    Log.section("重载配置")

    local _, note = Config.load(Util.script_dir)
    Log.emit("配置: " .. tostring(note))
    if Config.load_error ~= nil then
        Log.emit("!! " .. tostring(Config.load_error))
    end

    Session.rot_step = tonumber(Config.get("rotate_step_deg")) or 15.0
    Session.step_cm = tonumber(Config.get("nudge_step_cm")) or 100
    Hud.enabled = Config.get("hud_enabled") == true
    Hud.duration = tonumber(Config.get("hud_seconds")) or 4.0

    -- ★ 逃生通道: 配置里把屏幕提示关掉之后，按 F8 要顺手把我们自建的控件收掉。
    --   否则它会一直挂在视口里（虽然现在改成"不吃输入"了，但没必要留着）。
    if Config.get("notify_try_notice_text") ~= true
        or Config.get("notify_own_widget") ~= true then
        local dropped = Hud.destroy_own_widget()
        Log.emit("屏幕提示控件: " .. (dropped and "已收回" or "无需收回"))
    end

    local gok, gwhy = Ghost.check_gate(nil)
    Log.emit("ghost_enabled = " .. tostring(Config.get("ghost_enabled")))
    Log.emit("投影门禁: " .. tostring(gok) .. "  " .. tostring(gwhy))
    Log.emit("")
    emit_lines(Config.brief_lines())
    Log.emit("")
    Log.emit("文件: " .. tostring(Config.path))
    if gok and Config.get("ghost_enabled") == true then
        Log.emit("现在按 K 就可以放投影了。")
    elseif not gok then
        Log.emit("门禁未过 —— 先按 N 跑能力探测。")
    else
        Log.emit("门禁已过，但总开关是关的（ghost_enabled = false）:")
        Log.emit("  在 " .. tostring(Config.path) .. " 里把它改成 true（或删掉那一行），再按 F8。")
    end
    flush_log()

    -- ★ 重载完给一行屏幕提示: 这一下"到底生效了什么"要看得见
    --   （F8 是最容易被怀疑"按了没用"的键）
    Notify.show(string.format("配置已重载: 投影门禁 %s, 屏幕提示 %s",
        gok and "通过" or "未过", Hud.enabled and "开" or "关"),
        string.format("config reloaded: gate=%s notify=%s",
            tostring(gok), tostring(Hud.enabled)))
end

-- ---------------------------------------------------------------------------
-- 换投影材质
--
-- 为什么需要这个键: 回读证据证明材质【确实设上去了】，但玩家看到的不是
-- 期望的半透明轮廓 —— 也就是说"这个材质本身看起来就是这样"。
-- 我看不到玩家的屏幕，所以不猜了: 给出 4 个候选，按一下换一个，
-- 玩家自己挑最像"蓝图幽灵"的那个。
-- ---------------------------------------------------------------------------

--- rebuild_ghost(reason, force)
---   force = true 时必须传: 换材质会先 Ghost.clear()，那会把 visible 设成 false，
---   于是"if not Ghost.visible then return"就直接返回，投影永远不回来。
---   ★ 2026-09-26 实测踩过: Ctrl+← 之后投影直接消失，按多次也不出现，
---     只有 Ctrl+→（放/收）才能弄回来。
local function rebuild_ghost(reason, force)
    if force ~= true and not Ghost.visible then return true end
    local place = Session.place()
    if place == nil then
        Log.emit("!! 拿不到玩家位置，无法重建投影")
        return false
    end
    local mode, idx = Session.filter()
    apply_placed_mask("重建投影")
    local okf, ferr = Ghost.fill(Session.bp, place, mode, idx)
    if not okf then
        Log.emit("!! 重建投影失败: " .. tostring(ferr))
        return false
    end
    Log.emit(string.format("  已重建（%s）: %s", tostring(reason),
        Ghost.describe()))
    return true
end

local function do_material_cycle(dir)
    -- ★★ 2026-09-28 修: 原来左/右方向键都调"下一档"（没传方向），
    --    于是往回切只能循环一圈（玩家反馈）。
    --    约定: 右 = 下一档，左 = 上一档。
    local sign = (dir == "left") and -1 or 1
    Log.clear()
    Log.section("投影材质")
    if not Session.active then
        Log.emit("还没有加载蓝图。先按 J。")
        flush_log()
        return
    end

    Ghost.cycle_material(sign)
    -- ★ 必须把新材质写回配置。
    --   因为 Ghost.prepare() 会从配置里读 ghost_material 覆盖 Ghost.material_mode，
    --   不写回的话"换材质"每次都被 prepare 打回原值 —— 按了等于没按。
    --   顺带好处: 选定的材质会跨重启保留。
    Config.set("ghost_material", Ghost.material_mode)
    pcall(function() Config.save() end)

    Log.emit("材质模式 -> " .. Ghost.material_description())
    Log.emit("  观感: " .. tostring(MATERIAL_CN[Ghost.material_mode] or "?"))
    Log.emit("  循环里的 4 档: " .. table.concat(Ghost.MATERIAL_MODES, " / "))
    Log.emit("  另可写进配置: " .. table.concat(Ghost.EXTRA_MATERIAL_MODES, " / "))
    Notify.show(string.format("投影材质 -> %s", tostring(MATERIAL_CN[Ghost.material_mode] or Ghost.material_mode)),
        string.format("material = %s", Ghost.material_mode))
    -- 控制台只打 ASCII（中文在上面几行日志里）
    print(TAG .. " material = " .. tostring(Ghost.material_mode)
        .. "  [" .. tostring(MATERIAL_ASCII[Ghost.material_mode] or "?") .. "]")

    local was_visible = Ghost.visible
    if was_visible then
        -- 材质挂在组件上，换材质必须重建组件
        Ghost.clear()
        local okp, perr = Ghost.prepare(Config)
        if not okp then
            Log.emit("!! 重建失败: " .. tostring(perr))
        else
            rebuild_ghost("换材质", true)      -- force: clear 之后 visible 是 false
            Log.emit("  材质回读(槽0): " .. tostring(
                Ghost.material_readback() or "(没记录)"))
        end
    else
        Log.emit("（投影是收起的，按 K 放置时会用这个材质）")
    end
    flush_log()
end

-- ---------------------------------------------------------------------------
-- 热键注册
-- ---------------------------------------------------------------------------

-- 绑定结果 bound/failed 在文件靠前处声明（见 TAG 下面）

local function try_bind(name, key_name, modifiers, fn)
    local key = nil
    pcall(function() key = Key[key_name] end)
    if key == nil then
        failed[#failed + 1] = key_name .. "(枚举里没有这个键)"
        return false
    end
    -- 统一用闭包包住原生调用（不把原生函数直接交给 pcall）——
    -- 这是 StaticFindObject 那次崩溃换来的规矩，所有原生调用一律照办。
    local ok = pcall(function()
        RegisterKeyBindAsync(key, modifiers or {}, fn)
    end)
    if not ok then
        ok = pcall(function() RegisterKeyBind(key, fn) end)
    end
    if not ok then
        failed[#failed + 1] = name
        return false
    end
    -- 复核（Keybinds mod 用同一个 API 判断）
    local verified = nil
    pcall(function() verified = IsKeyBindRegistered(key, modifiers or {}) end)
    if verified == false then
        failed[#failed + 1] = name .. "(注册后复核为未注册)"
        return false
    end
    bound[#bound + 1] = name
    return true
end

-- ---------------------------------------------------------------------------
-- 启动
-- ---------------------------------------------------------------------------

print(TAG .. " ================================================")
print(TAG .. " PWProjection loading (blueprint projection mod)")
print(TAG .. " BUILD = " .. tostring(Util.BUILD))
print(TAG .. " ================================================")

local cfg_values, cfg_note = nil, "(读取失败)"
pcall(function() cfg_values, cfg_note = Config.load(Util.script_dir) end)
Log.emit("配置: " .. tostring(cfg_note))
-- ★ 配置文件写法有问题时要**一眼看到**（玩家 2026-09-29 实测踩过:
--   往文件里另起了一个 `{}` 加键 ⇒ 旧版严格解析会**整份退回默认值**，
--   连 ghost_enabled 都掉回 false、投影被锁，而他只看到"我的配置没生效"。）
if Config.multi_object_warn ~= nil then
    Log.emit("!! " .. tostring(Config.multi_object_warn))
    print(TAG .. " !! config has multiple top-level {} objects (merged this time)")
end

Sched.detect()

-- ---------------------------------------------------------------------------
-- ★ 日志"攒够再写"（2026-09-29 玩家提的策略）
--
--   放置路径上已经**没有**写盘/写控制台了（逐行只进内存缓冲）；
--   这一条是给日志一个**稳定的落盘时机**，不再依赖"碰巧发生的按键/提示":
--     · 隔 `log_flush_interval_s` 秒（默认 5）至少落一次；
--     · 缓冲攒够 `log_flush_lines` 行（默认 200）也落一次。
--   崩溃代价: 最多丢这几秒的**诊断日志**（游戏数据完全不受影响）。
--   每 5 秒一次的定时回调本身开销可以忽略（没有内容要写时它什么都不做）。
-- ---------------------------------------------------------------------------
local function log_autosave_tick()
    pcall(function()
        if Log.maybe_flush ~= nil then Log.maybe_flush() end
    end)
    -- 下一定时（自续；不依赖任何按键/事件）
    Sched.game_thread(log_autosave_tick, 2500)
end

pcall(function()
    local iv = tonumber(Config.get("log_flush_interval_s"))
    local ln = tonumber(Config.get("log_flush_lines"))
    if iv ~= nil and iv > 0 then Log.autosave_interval_s = iv end
    if ln ~= nil and ln > 0 then Log.autosave_lines = ln end
    if Log.autosave_interval_s > 0 then
        Sched.game_thread(log_autosave_tick, 2500)
        Log.line(string.format(
            "日志落盘策略: 每 %.0f 秒或攒够 %d 行写一次（放置路径上不写盘）",
            Log.autosave_interval_s, Log.autosave_lines))
    end
end)

-- 参数同步到会话
Session.rot_step = tonumber(Config.get("rotate_step_deg")) or 15.0
Session.step_cm = tonumber(Config.get("nudge_step_cm")) or 100
Hud.enabled = Config.get("hud_enabled") == true
Hud.duration = tonumber(Config.get("hud_seconds")) or 4.0

-- 蓝图库
local bp_dir = Config.get("blueprint_dir")
if type(bp_dir) ~= "string" or bp_dir == "" then
    bp_dir = Util.join(Util.mod_dir, "blueprints")
end
local lib_ok, lib_err = Library.init(bp_dir)
if not lib_ok then
    Log.emit("!! 蓝图库目录不可用: " .. tostring(lib_err))
end
-- 刷新蓝图库索引。整体 pcall：这一步失败绝不能拖垮启动流程。
-- 默认不扫目录（不 spawn cmd.exe），只读 index.txt。
local n_entries, lib_note = 0, "(未刷新)"
pcall(function()
    n_entries, lib_note = Library.refresh(
        Config.get("library_scan_on_refresh") == true)
end)
Log.emit(string.format("蓝图库: %d 张   %s", n_entries, tostring(lib_note)))

-- 网格覆盖表（可选）。读取失败不影响任何功能。
local n_ov, ov_note = 0, "(未读取)"
pcall(function() n_ov, ov_note = MeshMap.load_overrides(Util.script_dir) end)
Log.emit("网格覆盖表: " .. tostring(ov_note))

-- 能力门禁（只读磁盘，不碰引擎）。同样不能拖垮启动。
local gate_ok, gate_why = false, "(未读取)"
pcall(function() gate_ok, gate_why = Ghost.check_gate(nil) end)
Log.emit("投影门禁: " .. tostring(gate_ok) .. "  " .. tostring(gate_why))

-- 换地图时【只丢引用、绝不碰引擎】。
--
-- ★★★ 2026-09-28: 这个钩子现在是"回标题 → 重进世界 → 闪退"那个 bug 的**正解**。
--
-- 为什么必须靠钩子（而不是"每次操作前比一下世界标记"）:
--   · 上个世界的对象已被引擎销毁，而 `Util.usable()` / `IsValid()` 会**撒谎**
--     （在废对象上返回 true）—— 所以"提前检测"本身就可能崩；
--   · 权威信号只有一个: **引擎自己告诉你"要换地图了"** —— 就是 LoadMapPre。
--     它只在真的换地图时触发，不会像轮询标记那样抖动。
--   · 回调里**只做 Lua 侧的引用清空**（Ghost.forget / Hud.drop_world_refs），
--     一个引擎接口都不调 —— 因此"在世界加载期做额外动作"这件事本身是安全的。
--
-- 历史: 这个钩子原来默认关（当时投影还没解锁、觉得没收益，且怕加载期出问题）。
--       现在它是必需的: 不注册它，"回标题再进世界"后第一次操作就可能崩。
local hook_on = (Config.get("hook_load_map_pre") == true)
local Main_hook_registered = false
if hook_on then
    if Main_hook_registered == true then
        Log.emit("LoadMapPre 钩子: 已注册过，跳过（F8 重载配置不会重复注册）")
    else
        local okH = pcall(function()
            RegisterLoadMapPreHook(function()
                -- ★ 只碰 Lua 状态，不碰引擎。任何一处真出问题也只记录、不抛出。
                pcall(function() Ghost.forget("LoadMapPre") end)
                -- ★ 同时忘掉"已放上的件"的名单与 actor 引用 ——
                --   跨世界持有 actor 引用正是这个钩子要防的事（野指针）。
                pcall(function() Placed.forget() end)
                pcall(function() Hud.drop_world_refs("LoadMapPre") end)
                pcall(function() Session.deactivate() end)
                pcall(function()
                    Log.emit("[hook] LoadMapPre: 已丢弃投影与提示控件的引用（不碰引擎）")
                    Log.flush()
                end)
            end)
        end)
        if okH then Main_hook_registered = true end
        local msg = okH and "LoadMapPre 钩子已注册（换地图时丢引用，防跨世界野指针）"
            or "!! LoadMapPre 钩子注册失败 —— 回标题/重进世界后可能崩，请看日志"
        Log.emit(msg)
        print(TAG .. " " .. msg)
    end
else
    Log.emit("!! LoadMapPre 钩子: 已按配置关闭（hook_load_map_pre=false）")
    Log.emit("   ★ 警告: 关掉它之后，「回标题 → 重进世界」后第一次操作可能闪退（跨世界野指针）")
    print(TAG .. " LoadMapPre hook: DISABLED (hook_load_map_pre=false)")
end

-- ---------------------------------------------------------------------------
-- ★★ 建造吸附（玩家真正要的那个"吸附"）: 挂游戏的放置请求钩子
--
-- 做什么: 手拿建筑准备放下时，如果它与投影里同类型的那一件对得上，
--         就把**这次放置请求里的坐标/朝向**改写成投影里那一件的精确值 ⇒
--         放下去正好在投影上。
--
-- ★ 为什么用钩子而不是"读预览对象": 游戏那个半透明预览 Lua 抓不到
--   （PWRecon 第四轮已实测，见 docs\踩坑记录.md §3f-7）；
--   而放置请求这条链路里**带着最终坐标**，是能改的那一环。
--
-- ★ 依赖注入: 把"读配置 / 拿当前投影"这两件事交给 main 提供 ——
--   这样 buildsnap 模块不必反向 require Ghost/Session，避免模块成环。
-- ---------------------------------------------------------------------------

BuildSnap.deps.get = function(k) return Config.get(k) end
-- ★★★ 2026-09-29 实测踩到的坑: `Placed.deps` **从来没被赋值过**！
--   `Placed.refresh_delta()` 里有 `local deps = Placed.deps; if deps == nil ... return`
--   ⇒ **兜底全扫一次都没跑过** ⇒ 拆除之后投影永远不恢复（玩家实测: 等 30 秒没反应）。
--   教训: 模块之间靠 `X.deps = {...}` 注入依赖时，**注入点也要有检查**
--   （否则"依赖没注入"会表现为"功能静默失效"，看不出任何错）。
Placed.deps = {
    get = function(k) return Config.get(k) end,
    context = function()
        if not Session.active or Session.bp == nil or not Ghost.visible then
            return nil
        end
        local place = Session.place()
        if place == nil then return nil end
        return Session.bp, place
    end,
}
-- ★ 游戏通知"有新建筑出现"时，除了 buildsnap 自己的落地确认，
--   也顺手把"这一件已经放上了 ⇒ 投影里别再画"办掉（玩家 2026-09-29 要求）。
--   复用 buildsnap 那一次 NotifyOnNewObject 注册: 一个回调比注册两次更稳。
BuildSnap.deps.on_new_object = function(obj)
    pcall(on_ghost_new_object, obj)
end
-- ★ 吸附那边"正要往哪一条记录放" ⇒ 投影立刻精确隐藏它（不用重扫）
BuildSnap.deps.on_placing = function(rec_idx)
    pcall(on_ghost_placing, rec_idx)
end
-- ★ 落地确认成功/失败 ⇒ 记下 actor / 撤销隐藏
BuildSnap.deps.on_placed_confirmed = function(rec_idx, actor)
    pcall(on_ghost_placed_confirmed, rec_idx, actor)
end
BuildSnap.deps.on_placed_failed = function(rec_idx)
    pcall(on_ghost_placed_failed, rec_idx)
end
BuildSnap.deps.context = function()
    -- 只在"投影正显示着 + 加载了蓝图"时给上下文；否则返回 nil（= 不工作）
    if not Session.active or Session.bp == nil or not Ghost.visible then
        return nil
    end
    local place = Session.place()
    if place == nil then return nil end
    return Session.bp, place
end
BuildSnap.deps.player_aim = function() return Session.aim() end
BuildSnap.deps.notify = function(cn, en) Notify.show(cn, en) end

do
    local okB, whyB = BuildSnap.install()
    Log.emit(string.format("建造吸附钩子: %s  %s", tostring(okB), tostring(whyB)))
    print(TAG .. " build-snap hook: " .. (okB and "OK" or "FAILED")
        .. " (" .. Util.ascii(tostring(whyB)) .. ")")
end

-- ---------------------------------------------------------------------------
-- 绑定
-- ---------------------------------------------------------------------------

try_bind("F7=help",        "F7", {}, on_direct("help", do_help))
try_bind("F8=reload-cfg",  "F8", {}, on_direct("reload-config", do_reload_config))
-- ★ 手动收起屏幕提示: 函数保留（Hud.hide_now），但**不绑定按键**。
--
-- 2026-09-27 玩家反馈与决定:
--   ① 自动消失已经生效（约 4 秒），所以手动键不再是必需的；
--   ② 我先试的 F10 **已经被"切方向键模式"占用**；
--   ③ 改用的 F6 **被另一个模组（FirstPerson）占用**。
--   ⇒ 结论: 不留按键（键位是稀缺资源，撞键的代价比"多一个手动键"大）。
--   想手动清屏时: 把 notify_autohide 打开等它自动消失，
--   或者需要的话再挑一个确认空闲的键来绑。
--   （Hud.hide_now() 本身保留，将来做"键位自定义"（待办 5）时可以挂上去。）
-- ★ 采集: 只有**一个**键（`Y`）。"玩家附近 / 全部"由配置决定 ——
--   `capture_radius_m > 0` = 附近；`= 0` = 全部建筑。
--   （玩家 2026-09-29: "保留一个采集键就好了"。原来的 U=全部 已去掉。）
try_bind("Y=capture", "Y",  {}, on_game_thread("capture", do_capture_key))
try_bind("J=library-next", "J",  {}, on_direct("library-next", do_library_next))
try_bind("K=ghost-toggle", "K",  {}, on_game_thread("ghost-toggle", do_ghost_toggle_key))
try_bind("L=layer-cycle",  "L",  {}, on_game_thread("layer-cycle", do_layer_cycle))
try_bind("H=resnap",       "H",  {}, on_game_thread("resnap", do_resnap))
try_bind("N=probe",        "N",  {}, on_game_thread("probe", do_probe))
-- ★ O: 屏幕提示通道探测（S9）。
--   ★ 必须走 on_game_thread: S9 要读引擎（FindAllOf / 反射 / 构造 FText）。
--   本项目的规矩是"**只要碰引擎就走游戏线程**"，只读也一样 ——
--   按 Y 采集也是只读，同样走游戏线程。在非游戏线程读引擎对象
--   正是早期几次崩溃的成因之一。
try_bind("O=notify-probe", "O",  {}, on_game_thread("notify-probe", do_probe_ui))

try_bind("NUM_8=fwd",   "NUM_EIGHT", {}, on_game_thread("fwd",
    function() do_nudge("fwd") end))
try_bind("NUM_2=back",  "NUM_TWO",   {}, on_game_thread("back",
    function() do_nudge("back") end))
try_bind("NUM_4=left",  "NUM_FOUR",  {}, on_game_thread("left",
    function() do_nudge("left") end))
try_bind("NUM_6=right", "NUM_SIX",   {}, on_game_thread("right",
    function() do_nudge("right") end))
try_bind("NUM_9=up",    "NUM_NINE",  {}, on_game_thread("up",
    function() do_nudge("up") end))
try_bind("NUM_3=down",  "NUM_THREE", {}, on_game_thread("down",
    function() do_nudge("down") end))
try_bind("ADD=rot-ccw", "ADD",       {}, on_game_thread("rot-ccw",
    function() do_rotate(1) end))
try_bind("SUB=rot-cw",  "SUBTRACT",  {}, on_game_thread("rot-cw",
    function() do_rotate(-1) end))
try_bind("NUM_5=reset", "NUM_FIVE",  {}, on_direct("reset-offset", do_reset_offset))
try_bind("NUM_0=step",  "NUM_ZERO",  {}, safe("step-cycle", do_step_cycle))
try_bind("MUL=material", "MULTIPLY", {}, on_game_thread("material-cycle",
    do_material_cycle))
-- ★ 小键盘 1: 紧急收回我们自建的提示控件（见 do_drop_notify_widget 的说明）
try_bind("NUM_1=drop-notify", "NUM_ONE", {}, on_game_thread("drop-notify",
    do_drop_notify_widget))
-- ★ 建筑吸附键（路线图待办 2）。
--   默认 **`U`**（配置 `snap_key` 可改）——为什么是字母键而不是小键盘:
--   ① **玩家的键盘是 84 配列（没有小键盘）**，2026-09-29 明确说过；
--   ② `Y U H J K L` 是**实测未被游戏占用**的那批键，而 `U` 原来是"采集全部"，
--      已并进 `Y` ⇒ 正好空出来；
--   ③ 功能键全被占了（F1~F4 是 UE4SS、F5/F6 是 FirstPerson、F11/F12 是全屏/截图）。
--   ★ 有小键盘的人**额外**也能按小键盘 7（下面自动加这个别名；键名不存在就跳过）。
--   ★ 主键名写错/枚举里没有 ⇒ 启动日志会写 "BIND FAILED"，并自动退回备用键 G。
local function key_exists(name)
    local k = nil
    pcall(function() k = Key[name] end)
    return k ~= nil
end

local snap_key = Config.get("snap_key")
if type(snap_key) ~= "string" or snap_key == "" then snap_key = "U" end
do
    local ok_snap = try_bind("snap=" .. snap_key, snap_key, {},
        on_game_thread("snap", do_snap))
    if not ok_snap then
        try_bind("snap-fallback-G", "G", {}, on_game_thread("snap-g", do_snap))
        Log.emit("!! 吸附键 " .. snap_key .. " 没绑上，已改用备用键 G")
    end
    -- 小键盘 7 当别名（有就绑，没有就悄悄跳过 —— 不写进"绑定失败"名单）
    if snap_key ~= "NUM_SEVEN" and key_exists("NUM_SEVEN") then
        try_bind("snap-alt=NUM_7", "NUM_SEVEN", {},
            on_game_thread("snap-num7", do_snap))
    end
end

-- ---------------------------------------------------------------------------
-- ★ 方向键 + 模式：给没有小键盘的键盘（84 配列 / 75%）
--
-- 只有 5 个键：↑ ↓ ← → 和 F9（切模式）。没有任何修饰键组合。
--
-- 为什么彻底放弃修饰键组合（2026-09-26 实测教训）:
--   UE4SS 的 RegisterKeyBindAsync(key, {}, fn) 在**按住修饰键时照样触发**。
--   所以 "Alt+↑" 会同时触发 "Alt+↑"（换步长）和 "↑"（往前走）——
--   玩家报"Alt+加方向键的同时也会进行移动或者旋转"。
--   这不是绑错，是"空修饰键列表"的语义就是"不看修饰键"。
-- ---------------------------------------------------------------------------

--- 切下一个模式
local function do_mode_cycle()
    local cur = 1
    for i = 1, #PLACE_MODES do
        if PLACE_MODES[i] == place_mode then
            cur = i
            break
        end
    end
    cur = cur + 1
    if cur > #PLACE_MODES then cur = 1 end
    place_mode = PLACE_MODES[cur]
    local label = PLACE_MODE_LABEL[place_mode] or place_mode
    Log.clear()
    Log.emit("方向键模式 -> " .. label)
    Log.emit("  模式顺序: move -> rotate -> material -> move")
    -- 控制台只打 ASCII，中文在上面那行日志里
    print(TAG .. " arrow mode = " .. tostring(place_mode))
    Notify.show("方向键模式 -> " .. label, "arrow mode = " .. tostring(place_mode))
    flush_log()
end

--- 方向键按下时的分发。dir: "fwd" | "back" | "left" | "right"
local function do_arrow(dir)
    if place_mode == "move" then
        -- 平移
        do_nudge(dir)
    elseif place_mode == "rotate" then
        -- 旋转 + 高度
        if dir == "left" then do_rotate(1)
        elseif dir == "right" then do_rotate(-1)
        elseif dir == "fwd" then do_nudge("up")
        elseif dir == "back" then do_nudge("down")
        end
    else
        -- 材质 / 分层 / 步长
        if dir == "left" or dir == "right" then do_material_cycle(dir)
        elseif dir == "fwd" then do_layer_cycle()
        elseif dir == "back" then do_step_cycle()
        end
    end
end

try_bind("UP=arrow",    "UP_ARROW",    {}, on_game_thread("arrow-fwd",
    function() do_arrow("fwd") end))
try_bind("DOWN=arrow",  "DOWN_ARROW",  {}, on_game_thread("arrow-back",
    function() do_arrow("back") end))
try_bind("LEFT=arrow",  "LEFT_ARROW",  {}, on_game_thread("arrow-left",
    function() do_arrow("left") end))
try_bind("RIGHT=arrow", "RIGHT_ARROW", {}, on_game_thread("arrow-right",
    function() do_arrow("right") end))

try_bind("F9=mode",  "F9",  {}, on_direct("mode-cycle", do_mode_cycle))
try_bind("F10=mode", "F10", {}, on_direct("mode-cycle2", do_mode_cycle))

-- ---------------------------------------------------------------------------
-- 启动总结
-- ---------------------------------------------------------------------------

print(TAG .. " bound: " .. table.concat(bound, ", "))
if #failed > 0 then
    print(TAG .. " BIND FAILED: " .. table.concat(failed, ", "))
end
print(TAG .. " ------------------------------------------------")
print(TAG .. " F7=help F8=reload-cfg  Y=capture  J=next-bp  K=ghost  U=snap")
print(TAG .. " L=layer H=resnap N=render-probe O=notify-probe")
print(TAG .. " snap key = U (numpad 7 alias; config snap_key)")
print(TAG .. " arrows=action F9=arrow-mode")
print(TAG .. " ------------------------------------------------")

Log.line("")
Log.line("================ PWPR 启动 ================")
Log.line("构建标记: " .. tostring(Util.BUILD)
    .. "    （改了功能就 +1；看日志第一眼先确认这一行，"
    .. "对不上说明部署的是旧版）")
Log.line("配置: " .. tostring(cfg_note))
Log.line("蓝图库: " .. tostring(lib_note))
Log.line("网格覆盖表: " .. tostring(ov_note))
Log.line("投影门禁: " .. tostring(gate_ok) .. " " .. tostring(gate_why))
Log.line("屏幕提示: " .. tostring(Hud.describe()))
Log.line("已绑定: " .. table.concat(bound, ", "))
if #failed > 0 then
    Log.line("绑定失败: " .. table.concat(failed, ", "))
end
Log.line("==========================================")
Log.flush()

end)   -- pcall(function() ... end)

if not ok_init then
    -- 这条只能用 print（Log 可能还没初始化好）。故意用 ASCII，避免控制台乱码。
    print("[PWPR] !! init failed (mod disabled, game NOT crashed): "
        .. tostring(init_err))
end
