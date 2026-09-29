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
local Resume = require("pwpr_resume")
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
    -- ★ 换蓝图后清掉"当前那一处"的指认（否则会把新蓝图的位置/进度写到上一张的记录里）
    pcall(function() Resume.current = nil; Placed.forget() end)
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
-- ★★★ 2026-09-29 玩家规格（问题 2/3 的最终定义）:
--   「按了 H 就直接当成用户**重新加载并投影**（J+K），当一个新的来，
--     只是通过这个方式的投影**不需要判断"沿用哪一处"**。」
--   ⇒ 于是这一份投影是"**新的一天，什么都没建**":
--     · 运行时"已放上"名单清空；
--     · **连"扫描式隐藏"也先不开**（否则扫描可能凭几何巧合把别处建过的认成"这里建过"，
--       玩家实测就是"把已有的那份记录投影搞过来了"）；
--     · 直到你**在这里真的放下一件**（精确通道）才开始记账 ✓
--   这个标志就是"这一份是新投影、还没在这里建过东西"。
local progress_fresh = false

--- ★★★ 2026-09-29 玩家实测（问题 3: "重新加载的也存不上了，按 H 的也存不上，偏偏有一次成功"）:
---   原来进度写回**只靠看门狗**（每 2.5 秒一次）+ 一道"相对基线的变化"判断。
---   而按 `K`/`H`/`U` 时都会 `snapshot_baseline()`（把当前名单当成新基线）——
---   于是"刚结算完、还没等到看门狗"的那几件，会在下一次按 K/H 时被当成基线的一部分
---   ⇒ **永远不会写回记录** ✗（"完全存不上"，偶尔一次是"没按任何键刚好等到看门狗"）。
---   ⇒ 现在: **名单一变就立刻写回**（内存记账，落盘仍然由 10 秒/收起/攒够 20 次批量做，
---     所以不会变成"每次放置都写文件"）。
---   这个变量在 `export_list_for_store` 定义之后被赋值（那之后才有换算能力）。
local bind_progress_now = nil

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
    if progress_fresh then
        -- ★ 这一份是"新投影"（按 H / 或按 K 时没有沿用任何记录）⇒ 它是**完整的**
        --   ⇒ 不跑扫描式隐藏，名单保持空（你在这里放下第一件之后才会开始记账）
        Ghost.skip = Placed.hidden
        if Ghost.skip == nil then Ghost.skip = {} end
        Log.emit("  [placed] 这一份是新投影（按 H 放的）⇒ 不跑扫描式认领，"
            .. "只记你亲手放下的；想认领这一片已有建筑请按 K")
        return 0
    end
    -- ★★★ 2026-09-29 玩家实测（第 1 个问题: "K 关掉再打开，建过的又都画出来"）:
    --   日志实证: `沿用记录: … 按它对齐（1 件）` 之后紧跟
    --   `!! 本次没能算出'已放上'名单（调用出错）⇒ Ghost.skip 保持 nil`
    --   ⇒ **进度本来载入成功了，却被这次失败的"全扫"清成了 nil** ✗✗
    --   ⇒ 现在: 全扫失败/返回 nil 时 **保留** 名单（不清空），并把**失败原因**写出来。
    --   清空只应该发生在"真的算出结果且结果是空"的时候。
    local ok, a, why = pcall(function()
        return Placed.refresh(Session.bp, Session.place())
    end)
    if ok and a ~= nil then
        Ghost.skip = Placed.hidden
        n = a
        -- ★ 全扫的结果也是"进度"（它可能让隐藏变多/变少）⇒ 立刻写回
        if bind_progress_now ~= nil and n > 0 then
            pcall(function() bind_progress_now("全扫后") end)
        end
    else
        Ghost.skip = Placed.hidden            -- ★ 保留（不是 nil！）
        if Ghost.skip == nil then Ghost.skip = {} end
        local why_txt
        if not ok then
            why_txt = "抛异常: " .. tostring(a)          -- pcall 失败: a = 错误信息
        else
            why_txt = "返回 nil，原因: " .. tostring(a)   -- 正常返回但没算出来
        end
        if why ~= nil then why_txt = why_txt .. " / " .. tostring(why) end
        Log.emit(string.format(
            "  [diag] !! 本次全扫没算出结果（%s）⇒ **保留**已载入的名单 %d 件",
            why_txt, Placed.count()))
    end
    Log.emit(string.format("  [diag] apply_placed_mask: 名单 %d 件（skip=%s）",
        Placed.count(), tostring(Ghost.skip ~= nil)))
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
    -- ★★★ 2026-09-29 玩家实测（"提示说去掉了，但投影还在"，且日志里
    --   `增量重灌: 1 个组件 / 223 个实例` 的 **223 永远不变** ⇒ 根本没排除）:
    --   `Placed.forget()` / `Placed.load_from()` 会**换一张新表**给 `Placed.hidden`，
    --   而 `Ghost.skip` 只在"放投影"那条路里重新指向它 ⇒ 中间只要按过 H/U/微调，
    --   两者就可能**指向不同的表** ⇒ 重灌时用的名单是旧的 ⇒ 那几件又被加回来 ✗
    --   ⇒ 这里在结算前先**强制对齐**（同一张表，永远同步）。
    Ghost.skip = Placed.hidden
    if Ghost.skip == nil then Ghost.skip = {} end
    Log.emit(string.format(
        "  [diag] 结算前: 名单 %d 件，本次结算 %d 件（%s）",
        Placed.count(), #list, tostring(reason)))
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
    -- ★★ 结算完**立刻写回记录**（不等看门狗 —— 否则按 K/H 时会被基线吞掉）
    if bind_progress_now ~= nil then
        pcall(function() bind_progress_now("结算后立刻写回") end)
    end
    return #list
end

-- ★★★ 2026-09-29 玩家第五轮实测抓到的最后一环:
--   「到 B 按 H……B **没放内容也记录了**」—— 日志里能看到
--   `扫到 0 件参照 ⇒ 保留上次的 3 件` 紧接着 `新增一处记录（第 2 处，3 件进度）`。
--   原因: 换位置那一刻，内存里的"已放上"名单**可能还残留着上一处的进度**
--   （扫描测不到东西时会"保留上次名单"），而 `bind_progress` 只看到"名单非空"
--   就把它绑到了新位置 ⇒ 凭空多一条记录。
--   ⇒ 现在加一道**基线**: 每次"投影定位/挪动"之后，把当时的名单快照下来当基线；
--     只有**相对基线发生了变化**（= 真的在这里放了/拆了东西）才允许写回记录。
--     这样"残留名单"只会被清掉或被基线挡住，**绝不会被当成新位置的进度**。
local progress_baseline = nil    -- [记录序号] = true

local function snapshot_baseline()
    progress_baseline = {}
    for idx in pairs(Placed.hidden) do progress_baseline[idx] = true end
end

local function progress_changed_since_baseline()
    if progress_baseline == nil then return false end
    local n_now, n_base = 0, 0
    for idx in pairs(Placed.hidden) do
        n_now = n_now + 1
        if progress_baseline[idx] ~= true then return true end
    end
    for _ in pairs(progress_baseline) do n_base = n_base + 1 end
    if n_now ~= n_base then return true end
    return false
end

--- ★★★ 2026-09-29 玩家实测抓到的**第三个真 bug**:
---   「中间有几次……似乎放了建筑也没存上」+「放置后过几秒也还在，按两下 K 重新投影也还在」。
---
---   真因: 按 `H`/`K` 换位置时会调 `sync_progress_to_anchor` → `Placed.forget()`，
---   而 `forget` 会**连"待处理队列"一起清空**（`Placed.pending`）。
---   于是"刚放下、还在等那 3 秒批量窗口"的那几件被**直接丢掉**:
---     ① 不会被隐藏 ⇒ 投影里还在画（玩家: "过几秒也还在"）；
---     ② 不会被记进进度 ⇒ 下次 K 恢复的是"没有它们"的进度（玩家: "没存上"）。
---   ⇒ 修法: **换位置之前先把队列结算掉**（`commit_pending_now`），
---     而且要用**旧的锚点**把它绑到"刚才建的那一片"上 —— 再动锚点。
--- ★ 某一处记录的"投影变换"（用来算它那批记录的世界坐标）
--- z 用当前会话的脚底/半高近似（换算容差 200 厘米足够吸收这点差异）
local function site_place_of(site, ref_place)
    if site == nil then return nil end
    local half_z = 0.0
    if ref_place ~= nil then half_z = ref_place.z - (Session.anchor.z or 0.0) end
    return {
        x = site.x + (site.ox or 0.0),
        y = site.y + (site.oy or 0.0),
        z = (site.z or 0.0) + (site.oz or 0.0) + half_z,
        yaw = site.yaw or 0.0,
    }
end

--- ★ 把"当前锚点下的一份序号"换算到某一处的坐标系（或反过来）
local function convert_list(place_a, list, place_b, bp)
    if place_a == nil or place_b == nil or list == nil then return nil end
    local out = nil
    pcall(function()
        out = Placed.convert_indices(bp or Session.bp, place_a, list, place_b, 200.0)
    end)
    return out
end

--- ★ 写回记录之前: 把"当前锚点下的序号"换算到**那一处自己的坐标系**
---   （进度是按"那一处的锚点"存的；当前投影可能已经挪过位置）
---   如果当前锚点不属于任何一处（要新建记录），就不用换算。
local function export_list_for_store()
    local list = Placed.export_list()
    local cur_place = Session.place()
    -- ★★★ 只认"就在这一处旁边"（默认 10 米）: 否则会把新位置放的件**换算进 53 米外的旧记录**
    --   ⇒ 旧位置明明没建那几件也要隐藏 ✗（玩家实测: "回填到旧位置"）
    local site = nil
    pcall(function()
        site = Resume.nearest_site_within(Session.bp_file, Session.anchor.x,
            Session.anchor.y, Session.anchor.z)
    end)
    if site == nil or cur_place == nil then return list end
    local src_place = site_place_of(site, cur_place)
    local conv = convert_list(cur_place, list, src_place)
    if conv == nil then return list end
    return conv
end

--- ★★★ 立刻把当前"已放上"名单写回记录（用**当前锚点**的坐标系）
---   —— 这是问题 3 的正解: 不再依赖"看门狗 + 基线"的时序。
bind_progress_now = function(why)
    if not Session.active or Session.bp_file == nil then return false end
    local size = (Session.bp and Session.bp.meta and Session.bp.meta.size) or nil
    local margin = (tonumber(Config.get("ghost_resume_margin_m")) or 20.0) * 100.0
    local list = export_list_for_store()
    local ok, n_or_err, is_new = Resume.bind_progress(Session.bp_file, list,
        Session.anchor, Session.yaw, Session.offset, size, margin)
    snapshot_baseline()
    if ok then
        Log.emit(string.format(
            "  [resume] %s: 进度已记入（本次 %d 件%s）",
            tostring(why), #list, is_new and "，**新开一处**" or ""))
    else
        Log.emit(string.format("  [resume] %s: 进度没写回（%s）",
            tostring(why), tostring(n_or_err)))
    end
    return ok
end


--- ★ 只要"在这里真的放下一件"（精确通道），这一份就不再是"新投影"了
local function mark_progress_started(rec_idx)
    -- ★ 注意: 这里**不再**解除 `progress_fresh`。
    --   玩家的规格是"按 H 就是一份新的投影" ⇒ 那一份**全程**只记"你亲手放下的"
    --   （精确通道），不参与扫描式认领 —— 否则扫描又会把附近的旧建筑认成"这里建过"
    --   （规则网格平移整格后几何上无法区分，这是实测踩到的坑）。
    --   想让它去认领已有建筑时，按 `K` 即可（K 走扫描 + 排他表）。
    Log.emit(string.format(
        "  [placed] 在这里放下了第一件（记录 #%s）⇒ 开始记账", tostring(rec_idx)))
end

local function commit_pending_now(why)
    if not Session.active or Session.bp_file == nil then return 0 end
    local n_pend = 0
    pcall(function() n_pend = Placed.pending_count() end)
    if n_pend == 0 then return 0 end
    Log.emit(string.format(
        "  [placed] %s: 先把还在等批量窗口的 %d 件结算掉（否则换位置会把它们丢掉）",
        tostring(why), n_pend))
    pcall(function() flush_placed_batch(why .. "前结算") end)
    -- ★ 关键: 用**此刻的锚点**（= 旧位置）把刚结算的进度绑到那一片上
    pcall(function()
        if bind_progress_now ~= nil then
            bind_progress_now("换位置前结算")
        else
            local size = (Session.bp and Session.bp.meta
                and Session.bp.meta.size) or nil
            local margin = (tonumber(Config.get("ghost_resume_margin_m"))
                or 20.0) * 100.0
            Resume.bind_progress(Session.bp_file, export_list_for_store(),
                Session.anchor, Session.yaw, Session.offset, size, margin)
            snapshot_baseline()
        end
    end)
    return n_pend
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
local resume_prog_ver = -1     -- 上一次同步给"进度记忆"的 Placed.version（去重用）
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

        -- ★ 进度同步进"位置/进度记忆"（只改内存；落盘由定时器/收起/攒够时批量做）
        --   ★★ 只在**进度真的变了**时才同步（`Placed.version`）——
        --   否则这里每 2.5 秒都会标脏，等于白白多写盘（玩家明确要求别乱写）。
        pcall(function()
            if Placed.version ~= resume_prog_ver and Session.active
                and Session.bp_file ~= nil then
                resume_prog_ver = Placed.version
                -- ★ 只有"相对这个锚点的基线**真的变了**"才写回 —— 残留名单写不进来
                if progress_changed_since_baseline() then
                    local size = (Session.bp and Session.bp.meta
                        and Session.bp.meta.size) or nil
                    local margin = (tonumber(Config.get("ghost_resume_margin_m"))
                        or 20.0) * 100.0
                    Resume.bind_progress(Session.bp_file, export_list_for_store(),
                        Session.anchor, Session.yaw, Session.offset, size, margin)
                    snapshot_baseline()
                end
            end
        end)

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
        -- ★ 微调之后更新"位置记忆"（只改内存；落盘交给定时器）
        pcall(function()
            local size = (Session.bp and Session.bp.meta and Session.bp.meta.size) or nil
            local margin = (tonumber(Config.get("ghost_resume_margin_m")) or 20.0) * 100.0
            Resume.remember(Session.bp_file, Session.anchor, Session.yaw,
                Session.offset, size, margin)
            if progress_changed_since_baseline() then
                Resume.bind_progress(Session.bp_file, export_list_for_store(),
                    Session.anchor, Session.yaw, Session.offset, size, margin)
                snapshot_baseline()
            end
        end)
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

--- ★★★ 2026-09-29 玩家第四轮实测抓到的**关键 bug**（这次是模型层面的）:
---   「在 A 投影并放置建筑；到 B 按 H，移动到 B，**且投影上缺少在 A 放置过的几个建筑的投影**……
---     按 U 只有 B 位置的投影，**也是缺了放置过建筑投影的**」
---
---   真因: 运行时那份"已放上"名单（`Placed.hidden` / `Ghost.skip`）是**按蓝图**存的，
---   不是**按位置**存的 ⇒ 把投影挪到 B 之后，它还在用 **A 的进度** ⇒
---   ① B 处的投影把"在 A 建过的那几件"也藏起来（那儿根本没建）✗；
---   ② 看门狗又把这个**非空**名单绑给了 B ⇒ B 凭空多出一条记录 ✗
---   （日志实证: `扫到 0 件参照 ⇒ 保留上次的 3 件` 紧跟 `新增一处记录（第 2 处，3 件进度）`）
---   ⇒ 现在: **投影每次定位/挪动，运行时名单都必须重新对齐到"锚点所在的那一片"** ——
---     那一片有记录就加载它的进度，**没有就清空**（绝不把别处的进度带过来）。
local function sync_progress_to_anchor(anchor, why)
    if not Session.active or Session.bp == nil or anchor == nil then return 0 end
    local margin = (tonumber(Config.get("ghost_resume_margin_m")) or 20.0) * 100.0
    local site = nil
    pcall(function()
        -- ★★★ 2026-09-29 玩家定稿（H 修好之后）: **"沿用"用蓝图范围（宽）**。
        --   分工:
        --     · `K` = "对齐到这个世界" —— 站在基地**任何角落**都该认出"我在哪一处"
        --       ⇒ 半径 = **蓝图包围盒一半 + `ghost_resume_margin_m`**（这张蓝图 ≈ 53 米）✓
        --     · `H` = "在脚下放一份**全新**投影" —— **完全不查**范围 ✓
        --     · **登记 / 写回进度** 仍用 `ghost_site_merge_m`（**10 米**，收紧）——
        --       否则"换个地方建"会被并进几十米外的旧记录 ✗（"回填到旧位置"那个 bug）
        --   这里与 K 路径的那次查找**必须一致**，否则会出现
        --   "那边说命中、这边说不命中"的矛盾状态。
        site = Resume.find_site(Session.bp_file, anchor.x, anchor.y, anchor.z, margin)
    end)
    local total = (Session.bp.buildings and #Session.bp.buildings) or nil
    Placed.forget()
    if site == nil then
        Log.emit(string.format(
            "  [resume] %s: 这一片还没有记录 ⇒ 运行时'已放上'名单清零"
            .. "（不把别处的进度带过来）", tostring(why)))
        Ghost.skip = Placed.hidden
        snapshot_baseline()
        return 0
    end
    local list = Resume.placed_of_site(site)
    local n = 0
    if list ~= nil then
        -- ★ 关键: 那一处的序号是"在它自己的锚点下"记的 ⇒ 换算到**当前锚点**再用
        local cur_place = Session.place()
        local src_place = site_place_of(site, cur_place)
        local conv = convert_list(src_place, list, cur_place)
        if conv ~= nil then
            if #conv ~= #list then
                Log.emit(string.format(
                    "  [resume] 进度换算: %d 件 → %d 件（锚点变了，按几何重新对上）",
                    #list, #conv))
            end
            list = conv
        end
        n = Placed.load_from(list, total)
    end
    Log.emit(string.format(
        "  [resume] %s: 这一片有记录 ⇒ 运行时名单按它对齐（%d 件）",
        tostring(why), n))
    -- ★ 名单换了新表 ⇒ 让"重灌用的那份"立刻指向同一张表（否则重灌会用旧名单）
    Ghost.skip = Placed.hidden
    snapshot_baseline()          -- ★ 定位完成 ⇒ 这里就是新的基线
    return n
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
        -- ★ 收起时立刻把"位置记忆"落一次盘（玩家可能马上退出游戏）
        pcall(function() Resume.remember(Session.bp_file, Session.anchor,
            Session.yaw, Session.offset); Resume.save(true) end)
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

    -- ★★★ 先结算"待处理队列"（用旧锚点）—— 否则这次换位置会把刚放的那几件丢掉
    pcall(function() commit_pending_now("放下投影") end)

    -- ★★ 2026-09-29 玩家需求（三轮迭代后的最终形态）:
    --   "上次没建完，重进游戏再来建 —— 投影能不能沿用上次的位置 + 进度"；
    --   而且**一张蓝图可以有多处记录**（A 处、B 处各自独立）。
    --   按 K 之前先问一句"这张蓝图一共有几处、我现在属于哪一处"；
    --   命中的那一处就把 锚点/朝向/微调/进度 全恢复（投影和已建好的部分就对上了）。
    --   · 判定按"蓝图包围盒 + 容许距离"（`ghost_resume_margin_m`）⇒ 站基地哪一角都算；
    --   · 想改到脚下: 按 `H`（会**新开一处**记录，不会把原来那处弄丢）；
    --   · 想换另一处: 按 `B` 循环切换。
    local resumed = false
    if Config.get("ghost_resume_last") == true then
        local px, py, pz = Session.player_pos()
        local margin = (tonumber(Config.get("ghost_resume_margin_m")) or 20.0) * 100.0
        -- ★★★ 2026-09-29 玩家定稿: K 的"沿用"用**蓝图范围（宽）** —— 站在基地任何角落
        --   按 K 都应认出"我在哪一处"（明细见 `sync_progress_to_anchor` 里的注释）。
        --   "换个地方建会不会被并进旧记录"由**登记半径**（10 米）把关，不靠这里 ✗
        local e, site_idx, why = Resume.find_site(Session.bp_file, px, py, pz, margin)
        if e ~= nil then
            Session.anchor.x, Session.anchor.y, Session.anchor.z = e.x, e.y, e.z
            Session.yaw = e.yaw or 0.0
            Session.offset.x, Session.offset.y, Session.offset.z =
                e.ox or 0.0, e.oy or 0.0, e.oz or 0.0
            resumed = true
            progress_fresh = false        -- ★ 沿用了某一处 ⇒ 按那一处的进度显示
            local n_all = #Resume.progress_sites(Session.bp_file)
            Log.emit(string.format(
                "  沿用上次的投影位置（%s，朝向 %.0f 度）。想改到脚下就按 H",
                tostring(why or "在范围内"), Session.yaw))
            if n_all > 1 then
                Log.emit(string.format(
                    "  ★ 这张蓝图有 %d 处放置记录，现在用的是第 %d 处；按 U 换下一处",
                    n_all, site_idx))
            end
            -- ★ 进度也一起恢复: 上次已经放上的那些件不再画（按 K 之后的全扫会再核对一遍）
            local n_prog = 0
            pcall(function()
                n_prog = sync_progress_to_anchor(Session.anchor, "沿用记录")
            end)
            if n_prog > 0 then
                Log.emit(string.format(
                    "  同时恢复了上次的进度: %d 件已建好的不再画"
                    .. "（放投影后的全扫会按当前世界核对一遍）", n_prog))
            end
        else
            -- ★ 这一片没有记录 ⇒ 运行时名单必须清空（**不能**把别处的进度带过来）
            --   ⚠️ 这里**不设** `progress_fresh`: 按 `K` 时**要**跑扫描 —— 它的用途正是
            --      "认领这一片**已经建好**的建筑"（玩家最常见的用法: 旧基地上继续建）。
            --      串味问题由"排他表"解决（别处已认领的实物，本次扫描不许再认领）。
            pcall(function()
                sync_progress_to_anchor(Session.anchor, "新位置")
            end)
            if Resume.last_note ~= nil then
                Log.line("  " .. tostring(Resume.last_note))
            end
        end
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
    -- ★ 2026-09-29 更正文案: 这里原来写"放下时已自动吸"，但 `snap_on_place` 默认已关
    --   （投影对齐会和手动微调打架，见 踩坑记录 §42）⇒ 现在写清楚"要按 U"。
    Log.emit("分层: L      换一处记录: U（这张蓝图存了多处放置记录时用）      重新定位到脚下: H      收起: 再按 K")

    -- ★ 屏幕提示: 放下投影先立刻给一行（别让玩家在自动对齐那一两秒里干等），
    --   吸附完成后**再发一行**（用 show_force 忽略节流 —— 见下面的包装函数）。
    -- ★ 记住这一次的位置（只改内存；落盘由定时器/收起/攒够时批量做）
    pcall(function()
        local size = (Session.bp and Session.bp.meta and Session.bp.meta.size) or nil
        Resume.remember(Session.bp_file, Session.anchor, Session.yaw,
            Session.offset, size)
    end)
    -- ★★ 屏幕提示里把**两个键**都讲清楚（玩家 2026-09-29 第二轮反馈:
    --    "初次投影的时候只提示了 H 可以移动到脚下，没提示可以按 U 切换之前的记录"）:
    --    · H = 把投影挪到脚下（那一处有进度时会记成新的一处）
    --    · U = 在这张蓝图的多处记录之间切换（**有记录时才提示**，没有就只提 H）
    local n_prog_sites = 0
    pcall(function() n_prog_sites = #Resume.progress_sites(Session.bp_file) end)
    local hint = resumed and "   （沿用上次位置；H 改到脚下" or "   （H 移到脚下"
    if n_prog_sites >= 1 then
        hint = hint .. string.format("；U 换一处记录，共 %d 处）", n_prog_sites)
    else
        hint = hint .. "）"
    end
    Notify.show(string.format("投影已放置: %d 件   材质 %s%s",
        Ghost.stats.instances or 0,
        tostring(MATERIAL_CN[Ghost.material_mode] or Ghost.material_mode),
        hint),
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
    -- ★★ 2026-09-29 玩家**三轮**实测后的最终规则:
    --   `H` = **只把投影挪到脚下**（当前这一片的位置跟着更新），
    --   **绝不新增记录** —— 记录只由"真放过建筑"产生（见 `Resume.bind_progress`）。
    --   历史: ① 第一版"H 覆盖唯一记录" ⇒ 玩家: 「C 的位置和进度就都没了」；
    --         ② 第二版"H 新开一处 + 复制进度" ⇒ 玩家: 「B 没放建筑也记录了，
    --            A 的记录没了」；
    --         ③ **现在**: 记录 = "有进度的那几片"，光挪投影不产生任何记录 ✓
    -- ★★★ 先结算待处理队列（**必须在 resnap 之前** —— 结算要靠此刻的锚点，
    --   也就是"你刚才建东西的那个位置"）
    pcall(function() commit_pending_now("按 H 挪动") end)
    local okr, rerr = Session.resnap()
    Log.clear()
    if not okr then
        Log.emit("!! " .. tostring(rerr))
        Notify.show("重新吸附失败: " .. tostring(rerr), "re-snap failed", "error")
        flush_log()
        return
    end
    Log.emit("已重新吸附到你的当前位置，偏移与旋转清零。")
    -- ★ 只更新"当前这一片"的位置；**不新增记录**（记录只由真进度产生）
    pcall(function()
        local size = (Session.bp and Session.bp.meta and Session.bp.meta.size) or nil
        local margin = (tonumber(Config.get("ghost_resume_margin_m")) or 20.0) * 100.0
        Resume.remember(Session.bp_file, Session.anchor, Session.yaw,
            Session.offset, size, margin)
    end)
    -- ★★★ 2026-09-29 玩家明确要求（第 2 个问题）:
    --   「按 H 移动过来的应该是**一份完整的新投影**，而不是缺了已建件的那份」。
    --   （原来我让它"按新锚点重新对齐"，方向错了 —— 那会把原处的进度带过来。）
    --   ⇒ H = 在这里**重新放一份投影** ⇒ 运行时"已放上"名单**清空**。
    --     注意: **不会**动任何记录（那一片的记录仍在文件里，按 K 走回原处照样恢复）。
    pcall(function()
        -- ★★★ 玩家 2026-09-29 明确要求（第 2 个问题）:
        --   「按了 H 就直接当成用户重新加载并投影（J+K），当一个新的来」。
        --   ⇒ 和 `J`（换蓝图）之后的状态完全一致:
        --     · 清掉"当前正在用哪一处"的指认（`Resume.current`）；
        --     · 清空运行时"已放上"名单 ⇒ 这是一份**完整的新投影**；
        --     · **不动任何记录**（走回原处按 K 照样能恢复那处的"缺件"投影）。
        Resume.current = nil
        progress_fresh = true          -- ★ 新投影（不参与"沿用哪一处"的判断）
        Placed.forget()
        Ghost.skip = Placed.hidden
        if Ghost.skip == nil then Ghost.skip = {} end
        snapshot_baseline()
        Log.emit("  [resume] 按 H: 按「重新加载并投影」处理 ⇒ 完整的新投影"
            .. "（'已放上'名单清空；记录不动）")
    end)
    -- ★★★ 2026-09-29 玩家实测抓到的**真根因**（他说"把 H 弄成重新加载+投影就行"，完全正确）:
    --   `refresh_projection(reason, rebuild)` 有一条"省事路径" —— `rebuild ~= true` 时
    --   它**只搬动投影的组件变换**（`Ghost.apply_transform`），**不重灌实例、也不重算
    --   "已放上"名单** ✗ 而 H 原来调的正是这条路径 ✗✗
    --   ⇒ A 处"已隐藏"的状态被**原样搬到 B**（投影只是平移，隐藏信息没重算）
    --     = 玩家看到的"W1 对应的位置还是不画"；
    --   ⇒ 再按 U 回 A，两边合并的状态又搬回去 = "W1、W2 都不显示" ✗
    --   ⇒ 修法（就是玩家的建议）: **H 做和 K 一样的完整重灌**，只是不做"范围内有没有记录"的校验。
    --     `rebuild = true` ⇒ 会走 `apply_placed_mask` + `Ghost.fill`；
    --     而 H 已经把 `progress_fresh` 置上 ⇒ 名单为空 ⇒ **一份完整的新投影** ✓
    if Ghost.visible then refresh_projection("重新吸附", true) end
    local n_all = 0
    pcall(function() n_all = #Resume.progress_sites(Session.bp_file) end)
    -- 提示里说清楚: 记录不会因为"挪一下投影"而增加
    if n_all > 0 then
        Log.emit(string.format(
            "  只挪了位置（记录不会因此增加）。这张蓝图现有 %d 处记录；"
            .. "按 U 可以换一处，真要新建记录得**在这里真放下建筑**", n_all))
        Notify.show(string.format("已移到脚下（%d 处记录；按 U 换一处）", n_all),
            "re-snapped; position updated")
    else
        Log.emit("  只挪了位置（这张蓝图还没有任何记录 —— 真放下建筑才会记录）。")
        Notify.show("已移到脚下（还没放过建筑 ⇒ 不产生记录）",
            "re-snapped; nothing recorded yet")
    end
    flush_log()
end

--- ★ `B` 键: 在"这张蓝图的多处放置记录"之间循环切换（玩家 2026-09-29 要求）
local function do_site_cycle()
    Log.clear()
    if not Session.active then
        Log.emit("还没有加载蓝图。")
        Notify.show("还没有加载蓝图（先按 J）", "no blueprint loaded", "error")
        flush_log()
        return
    end
    Log.section("换一处记录")
    -- ★ 同样先结算（换记录 = 换位置，队列不结算就会被丢掉）
    pcall(function() commit_pending_now("换一处记录") end)
    local site, idx, total = nil, 0, 0
    pcall(function() site, idx, total = Resume.cycle(Session.bp_file) end)
    if site == nil then
        Log.emit("这张蓝图还没有任何记录（先按 K 放一次投影）。")
        Notify.show("这张蓝图还没有记录", "no recorded site for this blueprint", "error")
        flush_log()
        return
    end
    -- 把投影挪到那一处，并恢复它的进度
    Session.anchor.x, Session.anchor.y, Session.anchor.z = site.x, site.y, site.z
    Session.yaw = site.yaw or 0.0
    Session.offset.x, Session.offset.y, Session.offset.z =
        site.ox or 0.0, site.oy or 0.0, site.oz or 0.0
    local n_prog = 0
    progress_fresh = false             -- ★ 切到某一处 ⇒ 按那一处显示
    pcall(function()
        Placed.forget()
        local list = Resume.placed_of_site(site)
        local total_rec = (Session.bp and Session.bp.buildings
            and #Session.bp.buildings) or nil
        if list ~= nil then n_prog = Placed.load_from(list, total_rec) end
    end)
    Log.emit(string.format("切到第 %d/%d 处记录: 锚点 (%.0f, %.0f, %.0f) 朝向 %.0f 度，"
        .. "进度 %d 件", idx, total, site.x, site.y, site.z, Session.yaw, n_prog))
    if Ghost.visible then
        -- ★ 同上: 换一处记录会把**那一处的名单**载进来 ⇒ 必须完整重灌才生效
    --   （省事路径只搬变换 ⇒ 上一处的隐藏状态会残留 ✗）
    refresh_projection(string.format("换到第 %d/%d 处记录", idx, total), true)
    else
        Log.emit("（投影当前没显示 —— 按 K 放出来就是这个位置）")
    end
    Notify.show(string.format("换到第 %d/%d 处记录（进度 %d 件）", idx, total, n_prog),
        string.format("site %d/%d", idx, total))
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
    Log.line("  " .. Resume.status_line())
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

-- ---------------------------------------------------------------------------
-- ★ "投影位置记忆"的落盘定时器（玩家要求:**别每次放置都写文件**）
--   每次放置/微调只改内存（几乎零开销）；这里每 10 秒（可配）批量落一次盘，
--   另外在"收起投影 / 按 F8 / 攒够 20 次改动"时也会立刻落一次。
-- ---------------------------------------------------------------------------
local function resume_tick()
    pcall(function()
        if Resume.tick ~= nil then Resume.tick() end
    end)
    Sched.game_thread(resume_tick, 5000)
end
pcall(function()
    Resume.init(Util.script_dir)
    local iv = tonumber(Config.get("resume_save_interval_s"))
    if iv ~= nil and iv > 0 then Resume.save_interval_s = iv end
    local n_loaded = 0
    if Resume.load() then
        for _ in pairs(Resume.entries) do n_loaded = n_loaded + 1 end
    end
    -- ★ 用 Log.emit（会进文件）而不是 Log.line（缓冲，会被第一次 Log.clear 冲掉）——
    --   2026-09-29 就是因为这行看不见，害我多绕了好几轮才找到"读盘被永久跳过"。
    Log.emit(string.format(
        "投影位置记忆: %s（已记 %d 张蓝图；落盘间隔 %.0f 秒，不是每次放置都写）",
        tostring(Resume.last_note or "已就绪"), n_loaded, Resume.save_interval_s))
    Log.flush()
    Sched.game_thread(resume_tick, 5000)
end)

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
-- ★★ 2026-09-29 事故后加的"防误配"闸 ②: 告诉吸附"这条记录是不是已经放上过了"
--   （已经放上/正在待处理队列里的，就不要再把玩家往那个位置按 —— 那儿已经被占了）
BuildSnap.deps.record_taken = function(idx)
    if idx == nil then return false end
    if Placed == nil then return false end
    if Placed.is_taken ~= nil then return Placed.is_taken(idx) == true end
    return false
end
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
    mark_progress_started(rec_idx)
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
--- ★★ 人物半高（厘米）—— 玩家 2026-09-29 定稿的判据要用它:
---   「吸附的时候能不能**高度差在人物一半以内**的时候就不判高度只根据 xy 决定是否吸附」
---   来源就是 K 放投影时读的那个胶囊体半高（实测 88 厘米，见 `Session.feet_offset_cm`）。
BuildSnap.deps.half_height_cm = function() return (Session.feet_offset_cm()) end

--- ★★ 2026-09-29 玩家提的方案（原话）:
---   「如果发现按吸附的高度不让放置（比如现在水面的这种情况），就在本次放置之后，
---     把投影地基的 z 轴也换到实际允许的位置，并且弹出一个提示，说因为地基吸附后的
---     高度不允许，所以才自动把投影的高度换了下之类的。」
---
--- 干什么: 把**整个投影的高度**挪 `dz` 厘米（`dz = 游戏允许的高度 − 我们按投影发的高度`），
---   并把这件事记进"位置记忆"（走的就是微调那条路: `refresh_projection` 里会
---   `Resume.remember` + 攒批写回），然后**明确告诉玩家**。
--- 为什么这样比"以后不吸高度"好: 水面/特殊地形上游戏认的高度和投影记录的高度本来就差
---   一截；把投影挪过去之后，**高度还能继续跟投影**（玩家要的手感），而且整份蓝图
---   在高度上也和现实对齐了。
--- 返回 true = 真的挪了（调用方据此决定"不降级"）；false = 条件不满足（别乱挪）。
BuildSnap.deps.on_z_rejected = function(id, dz, why)
    if type(dz) ~= "number" or dz ~= dz then return false end
    local absd = math.abs(dz)
    -- 太小 = 噪声（不是高度问题）；太大 = 根本不是"高度不允许"，别把整份蓝图挪飞
    if absd < 5.0 or absd > 500.0 then return false end
    if not Session.active or not Ghost.visible then return false end
    if Session.offset == nil then return false end

    Session.offset.z = (tonumber(Session.offset.z) or 0.0) + dz
    local id_txt = tostring(id or "这一类建筑")
    local ok = pcall(function()
        refresh_projection(string.format("高度自适应（%s）", tostring(why or "游戏不认这个高度")))
    end)
    pcall(function()
        Notify.show(string.format(
            "「%s」吸附后的高度游戏不认 ⇒ 已自动把**投影高度**挪 %+.0f 厘米"
            .. "（对齐到游戏允许的高度），再放一次即可；高度继续跟投影",
            id_txt, dz), string.format("auto-fixed projection height by %+.0f cm", dz))
    end)
    Log.emit(string.format(
        "  [bsnap] ★ 高度自适应: %s 吸附的高度被游戏拒绝 ⇒ **投影 Z 偏移 %+.0f 厘米**"
        .. " ⇒ 现在 %s（已记进位置记忆；不满意就用方向键/小键盘 9、3 手动微调）",
        id_txt, dz, Session.offset_note()))
    Log.flush()
    return ok and true or false
end

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
-- ★ U = 在这张蓝图的多处放置记录之间切换（玩家 2026-09-29 定稿）。
--   ★★ 为什么是 `U` 而不是 `B`: **`B` 是游戏自己的建造模式入口**（玩家指出:
--     「B 键是游戏自用的，建筑模式入口」）—— 占游戏自己的键会互相打架，
--     这类键一律不碰（规矩 4c）。
--   ★ 原来 `U` 是"投影对齐到附近原建筑"—— 有了位置记忆之后它基本用不上
--     （而且那条路要枚举关卡建筑），所以让位给这个新功能，并改成**默认不绑键**
--     （想用的人自己在配置里设 `snap_key`，见下面那段）。
try_bind("U=site-cycle",   "U",  {}, on_game_thread("site-cycle", do_site_cycle))
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

-- ★★ "投影对齐到附近原建筑"（`do_snap`）—— **默认不绑任何键**（2026-09-29 玩家要求）。
--   为什么: ① `U` 让位给了新功能"换一处记录"（同一张蓝图的多处放置记录之间切换）；
--           ② 有了位置记忆之后，"靠对齐去猜位置"基本用不上；
--           ③ 这条对齐要**枚举关卡建筑**去配对（`Capture.list_build_actors`）——
--              属于"会碰引擎对象"的路，默认不占键 = 平时不会误按到它。
--   想继续用: 在 `pwpr_config.json` 里设 `"snap_key": "G"`（或别的空闲字母），
--   **改完要重启游戏**（键位只在启动时注册，按 F8 不重绑）。
--   ⚠️ 不能设成 `U`（现在是换一处记录）或 `B`（**游戏自己的建造模式入口**）——
--      这里会把这两个值当成"没设"，并在日志里说明。
local snap_key = Config.get("snap_key")
if type(snap_key) ~= "string" then snap_key = "" end
snap_key = string.upper(snap_key)
if snap_key == "U" or snap_key == "B" then
    Log.emit(string.format(
        "!! snap_key 设成了 %s —— 但 %s 现在另有用途（%s）⇒ 这次**不绑对齐键**。"
        .. "想用投影对齐请换一个空闲字母（例 G）",
        snap_key, snap_key,
        (snap_key == "U") and "换一处记录" or "游戏自己的建造模式入口"))
    snap_key = ""
end
if snap_key ~= "" then
    local ok_snap = try_bind("snap=" .. snap_key, snap_key, {},
        on_game_thread("snap", do_snap))
    if not ok_snap then
        Log.emit("!! 投影对齐键 " .. snap_key .. " 没绑上（名字写错？）")
    end
    -- 小键盘 7 当别名（有就绑，没有就悄悄跳过 —— 不写进"绑定失败"名单）
    if snap_key ~= "NUM_SEVEN" and key_exists("NUM_SEVEN") then
        try_bind("snap-alt=NUM_7", "NUM_SEVEN", {},
            on_game_thread("snap-num7", do_snap))
    end
else
    Log.emit("投影对齐: 默认不绑键（有位置记忆之后用不上；想用就设 snap_key，例 G）")
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
print(TAG .. " U=site-cycle  B=game's own build-mode key (never bind)  snap key = unbound by default (config snap_key)")
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
