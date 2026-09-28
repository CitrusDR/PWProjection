--[[ ===========================================================================
  PWPR · log  ——  控制台 + 文件双写

  为什么双写:
    · 控制台（UE4SS 窗口）是"立刻能看到"的通道，但它只吃 ASCII，
      中文会变成乱码（见 docs/踩坑记录.md 3d），所以控制台走 Util.ascii。
    · 文件（UTF-8 BOM）保留中文，方便事后把日志整份发出来排查。

  用法:
    Log.init(Util.script_dir)
    Log.emit("...")        立刻写控制台，进缓冲
    Log.flush("pwpr.log")  缓冲追加落盘
=========================================================================== ]]

local Util = require("pwpr_util")

local Log = {}

Log.dir = nil
Log.default_file = "pwpr.log"
Log.buffer = {}
Log.echo = true
Log.buffer_limit = 8000
-- ★ 落盘策略（可在配置里改，见 pwpr_config.lua 的 log_flush_*）
Log.autosave_interval_s = 5.0    -- 隔多少秒至少落一次盘
Log.autosave_lines = 200         -- 缓冲攒够多少行就落盘
Log.last_flush_clock = 0.0       -- 上次真正写盘的时刻（os.clock）

function Log.init(dir, default_file)
    Log.dir = dir
    if default_file ~= nil then Log.default_file = default_file end
    Log.buffer = {}
    return Log
end

function Log.path_of(name)
    if Log.dir == nil then return tostring(name) end
    return Util.join(Log.dir, name or Log.default_file)
end

--- 只进缓冲，不写控制台
function Log.line(s)
    Log.buffer[#Log.buffer + 1] = tostring(s)
    if #Log.buffer > Log.buffer_limit then
        table.remove(Log.buffer, 1)
    end
end

--- 进缓冲 + 写控制台（ASCII 化）
function Log.emit(s)
    s = tostring(s)
    Log.line(s)
    if Log.echo then
        print(Util.TAG .. " " .. Util.ascii(s))
    end
end

function Log.emitf(fmt, ...)
    Log.emit(string.format(fmt, ...))
end

function Log.linef(fmt, ...)
    Log.line(string.format(fmt, ...))
end

Log.emit_ = Log.emit

function Log.section(title)
    Log.emit("")
    Log.emit("==== " .. tostring(title) .. " ====")
end

function Log.clear()
    Log.buffer = {}
end

--- 把缓冲追加到文件。返回 true/false
--- ★ **热路径写日志**: 只进缓冲，**不写控制台**。
---
--- 为什么（2026-09-29 性能修复）: `Log.emit` 会 `print(...)` 到 UE4SS 控制台，
---   而那是**窗口 + 另一份日志**的 I/O —— 在"玩家每秒操作好几次"的路径上很贵。
---   放置结果这类"每次都会发生"的行用这个；**错误/关键决策仍用 `Log.emit`**
---   （那些要立刻在控制台看见，而且不频繁）。
function Log.hot(s)
    Log.line(s)
end

--- ★ **按量/按时间落盘**（2026-09-29 玩家提的策略，见下）
---
--- 玩家原话:「不每次放置都写到文件或者其他性能消耗大的操作，只记在内存，
---   满一定数量或隔多少秒，再存放一次」。
---
--- 现状核对（重要）: **放置那条路径上已经没有写盘、也没有写控制台了** ——
---   逐行都是 `Log.line`（只进内存表）；控制台的 `print` 也在上一轮从热路径移走了。
---   所以这一条**不是为了省放置时的开销**（那里已经是 0），而是为了:
---     ① 不再依赖"碰巧发生的事件"（发提示/按键）来落盘；
---     ② **崩溃时最多只丢这几秒**的日志（原来长时间不落盘可能丢一大段）。
---   代价/风险: 崩溃时可能丢"最后一次落盘之后"的那几行（纯诊断信息，
---   游戏数据完全不受影响；内存缓冲本身也有 8000 行上限，不会无限涨）。
function Log.maybe_flush(force)
    if #Log.buffer == 0 then return false end
    local now = os.clock()
    local last = Log.last_flush_clock or 0.0
    local due_lines = (#Log.buffer >= (Log.autosave_lines or 200))
    local due_time = ((now - last) >= (Log.autosave_interval_s or 5.0))
    if force == true or due_lines or due_time then
        Log.last_flush_clock = now
        return Log.flush()
    end
    return false
end

--- ★ **节流写盘**（2026-09-29 加的，为修"放置时还是有点卡"）
---
--- 为什么需要: `Log.flush()` 每次都会**同步写一次文件**。放置那条路径上
---   一次就有好几处 flush（决策、结果、确认…），连放时就是"每放一块写好几次盘"。
---   在 UE4SS 的 Lua 里这是实打实的开销，而且它会和游戏自己的放置工作叠在一起。
---
--- 语义: 距上次真正写盘不足 `min_s` 秒时**只进缓冲、不写盘**；
---   内容不会丢 —— 下一次 flush（或下一批清算）会把缓冲一起写出去。
---   **错误/异常行仍然应该用 `Log.flush()` 立刻落盘**（那些是排查的关键证据）。
function Log.throttled_flush(min_s, name)
    local now = os.clock()
    local last = Log.last_flush_clock or 0.0
    if (now - last) < (min_s or 1.0) then
        return false        -- 攒着，等下一次
    end
    Log.last_flush_clock = now
    return Log.flush(name)
end

function Log.flush(name, reset_after)
    local path = Log.path_of(name)
    local text = table.concat(Log.buffer, "\r\n")
    if text == "" then return true end
    text = text .. "\r\n"
    local ok, err = Util.append_file(path, text)
    if not ok then
        if Log.echo then
            print(Util.TAG .. " LOG WRITE FAILED: " .. Util.ascii(tostring(err)))
        end
        return false
    end
    if reset_after ~= false then Log.buffer = {} end
    return true
end

--- 覆盖写（用于 probe / 一次性报告，每次从干净内容开始）
function Log.dump(name, extra_lines)
    local path = Log.path_of(name)
    local all = {}
    for i = 1, #Log.buffer do all[i] = Log.buffer[i] end
    if extra_lines then
        for i = 1, #extra_lines do all[#all + 1] = extra_lines[i] end
    end
    local ok, err = Util.write_file(path, table.concat(all, "\r\n") .. "\r\n", true)
    if not ok then
        if Log.echo then
            print(Util.TAG .. " LOG DUMP FAILED: " .. Util.ascii(tostring(err)))
        end
        return false
    end
    if Log.echo then
        print(Util.TAG .. " wrote " .. Util.ascii(path))
    end
    return true
end

return Log
