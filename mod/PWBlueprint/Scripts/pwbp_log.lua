--[[ ===========================================================================
  PWBP · log  ——  控制台 + 文件双写

  为什么双写:
    · 控制台（UE4SS 窗口）是"立刻能看到"的通道，但它只吃 ASCII，
      中文会变成乱码（见 docs/踩坑记录.md 3d），所以控制台走 Util.ascii。
    · 文件（UTF-8 BOM）保留中文，方便事后把日志整份发出来排查。

  用法:
    Log.init(Util.script_dir)
    Log.emit("...")        立刻写控制台，进缓冲
    Log.flush("pwbp.log")  缓冲追加落盘
=========================================================================== ]]

local Util = require("pwbp_util")

local Log = {}

Log.dir = nil
Log.default_file = "pwbp.log"
Log.buffer = {}
Log.echo = true
Log.buffer_limit = 8000

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
