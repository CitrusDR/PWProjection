--[[ ===========================================================================
  PWPR · library  ——  蓝图库（纯 Lua 文件操作）

  目录:  <mod>\blueprints\            （不存在会自动 mkdir）
  索引:  <mod>\blueprints\index.txt  每行一个文件名（不含路径）

  为什么要索引文件:
    Lua 标准库没有"列目录"。io.popen 在 UE4SS 上不保证存在，
    所以真相来源是我们自己维护的 index.txt；io.popen 可用时用它刷新索引，
    不可用也不影响基本功能。

  另外支持"手抄路径": 直接把 .blueprint.json 放进 blueprints\ 目录后，
  按 J 会把目录里能读到的文件都纳入列表（走 popen；没有 popen 就只能
  重新导出一次，或手工把文件名写进 index.txt）。
=========================================================================== ]]

local Util = require("pwpr_util")
local Json = require("pwpr_json")
local BP = require("pwpr_bp")
local Config = require("pwpr_config")

local Library = {}

Library.dir = nil
Library.entries = {}       -- { {file=, name=, mtime=?}, ... }
Library.current = 0        -- 当前选中的下标（0 = 无）
Library.last_error = nil

local INDEX_NAME = "index.txt"

function Library.init(base_dir)
    Library.dir = base_dir
    Library.entries = {}
    Library.current = 0
    -- 注意：这里【不】建目录。
    -- 启动期跑 os.execute('mkdir ...') 会在游戏启动过程中 spawn 一个 cmd.exe，
    -- 而启动期是最不该有多余动作的时候。改成保存时按需建。
    Library.last_error = nil
    return true, nil
end

--- 按需建目录（只在真的要写文件时调用）
function Library.ensure_dir()
    if Library.dir == nil then return false, "库目录未初始化" end
    if Library.dir_ready then return true, nil end
    local ok, err = Util.mkdir(Library.dir)
    if not ok then
        Library.last_error = "建目录失败: " .. tostring(err)
        return false, Library.last_error
    end
    Library.dir_ready = true
    return true, nil
end

function Library.index_path()
    if Library.dir == nil then return nil end
    return Util.join(Library.dir, INDEX_NAME)
end

function Library.file_path(file_name)
    if Library.dir == nil then return nil end
    return Util.join(Library.dir, file_name)
end

--- 名字 -> 文件名
---
--- ★★ 2026-09-28 玩家要求: 文件名里带上**易读的采集时间**。
---   起因: 他重采了很多次，却分不清"这份蓝图到底是什么时候采的"
---   （当时的真实原因是我另一个 bug，但这条需求本身很合理 ——
---     同一个基地反复采集时，能一眼看出哪份是哪份）。
---
---   怎么做的: 文件名 = `<基地名>_<YYYY-MM-DD_HHMM>.blueprint.json`，
---   例如 `base_-1620_-609_2026-09-28_1430.blueprint.json`。
---   ⚠️ 这样一来**每次采集都会产生一个新文件**（不覆盖旧的）——
---     这是"能区分版本"的代价；不想要就在配置里关掉:
---     把 `blueprint_name_with_time` 设为 false（关掉后按基地名覆盖，只留一份）。
function Library.file_name_for(name)
    local base = Util.slug(name)
    -- ★ 注意: Config.get 只接受一个参数（缺省值写在 DEFAULTS 里），
    --   所以这里用"== false 才关掉"来表达"默认开、可显式关"。
    if Config.get("blueprint_name_with_time") == false then
        return base .. ".blueprint.json"
    end
    -- os.date 在 UE4SS 的 Lua 里可用；万一不可用就退回"不写时间"，
    -- 绝不能因为时间戳拿不到就让采集失败。
    local ok, stamp = pcall(function() return os.date("%Y-%m-%d_%H%M") end)
    if not ok or type(stamp) ~= "string" or stamp == "" then
        return base .. ".blueprint.json"
    end
    return base .. "_" .. stamp .. ".blueprint.json"
end

-- --------------------------------------------------------------------------
-- 索引
-- --------------------------------------------------------------------------

local function add_entry(file, name, mtime)
    for i = 1, #Library.entries do
        if Library.entries[i].file == file then
            if name then Library.entries[i].name = name end
            if mtime then Library.entries[i].mtime = mtime end
            return i
        end
    end
    Library.entries[#Library.entries + 1] = {
        file = file, name = name or file, mtime = mtime,
    }
    return #Library.entries
end

--- 读 index.txt
function Library.load_index()
    Library.entries = {}
    local path = Library.index_path()
    if path == nil then return false end
    local text = Util.read_file(path)
    if text == nil then return false end
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            -- 允许 "文件名|显示名" 形式
            local file, disp = line:match("^(.-)|(.*)$")
            if file == nil then file, disp = line, line end
            add_entry(file, disp)
        end
    end
    return true
end

function Library.save_index()
    local path = Library.index_path()
    if path == nil then return false, "库目录未初始化" end
    if Library.dir_ready ~= true then return false, "库目录尚未建立" end
    local lines = { "# PWProjection 蓝图索引，每行一个文件（相对 blueprints\\ 目录）" }
    for i = 1, #Library.entries do
        local e = Library.entries[i]
        lines[#lines + 1] = e.file .. "|" .. tostring(e.name or e.file)
    end
    return Util.write_file(path, table.concat(lines, "\r\n") .. "\r\n", true)
end

--- 用 dir 命令列出目录里的 .blueprint.json（io.popen 可用才走这条）
function Library.scan_directory()
    if Library.dir == nil then return false, "库目录未初始化" end
    if type(io.popen) ~= "function" then
        return false, "io.popen 不可用"
    end
    if Library.dir:find('"', 1, true) or Library.dir:find("[\r\n]") then
        return false, "目录路径包含非法字符"
    end
    local cmd = 'dir /b /a-d "' .. Library.dir .. '\\*.blueprint.json" 2>nul'
    local ok, pipe = pcall(function() return io.popen(cmd) end)
    if not ok or pipe == nil then return false, "popen 失败" end
    local found = 0
    -- 整个读取过程也要 pcall：管道中途出错不能把异常抛到启动流程里
    -- （启动流程抛异常 = 热键全都不注册 = mod 直接失效）
    local read_ok = pcall(function()
        for line in pipe:lines() do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" then
                add_entry(line, nil)
                found = found + 1
            end
        end
    end)
    pcall(function() pipe:close() end)
    if not read_ok then
        return false, "读目录输出时出错"
    end
    return true, found
end

--- 刷新列表。
--- allow_scan 必须显式传 true 才会去 spawn 一个 cmd.exe 扫目录。
--- 默认只读 index.txt（那个文件由 Library.save 自动维护）。
function Library.refresh(allow_scan)
    Library.load_index()

    if allow_scan ~= true then
        table.sort(Library.entries, function(a, b)
            return tostring(a.file) < tostring(b.file)
        end)
        return #Library.entries, string.format("索引 %d 项", #Library.entries)
    end

    local ok, n = Library.scan_directory()
    table.sort(Library.entries, function(a, b)
        return tostring(a.file) < tostring(b.file)
    end)
    if ok then
        Library.save_index()
        return #Library.entries, string.format("索引 %d 项（目录扫描补充 %d）",
            #Library.entries, n or 0)
    end
    return #Library.entries, string.format("索引 %d 项（目录扫描不可用: %s）",
        #Library.entries, tostring(n))
end

-- --------------------------------------------------------------------------
-- 读写
-- --------------------------------------------------------------------------

--- 保存蓝图。name 用来生成文件名
function Library.save(name, bp)
    local path = Library.index_path()
    if path == nil then return nil, "库目录未初始化" end
    local ok_dir, derr = Library.ensure_dir()
    if not ok_dir then return nil, tostring(derr) end

    local file = Library.file_name_for(name)
    local full = Library.file_path(file)

    local text, err = Json.encode(bp, true)
    if text == nil then return nil, "编码失败: " .. tostring(err) end

    local ok, werr = Util.write_file(full, text .. "\n", true)
    if not ok then return nil, "写文件失败: " .. tostring(werr) end

    add_entry(file, bp.meta and bp.meta.name or name)
    Library.save_index()
    return full
end

--- 读一个蓝图文件（只给文件名，不给全路径 —— 防目录穿越）
function Library.load(file)
    if type(file) ~= "string" or file == "" then return nil, "文件名非法" end
    if file:find("[/\\]") or file:find("%.%.") then
        return nil, "文件名不能包含路径分隔符"
    end
    local full = Library.file_path(file)
    local text, rerr = Util.read_file(full)
    if text == nil then return nil, "读取失败: " .. tostring(rerr) end
    local bp, perr = Json.decode(text)
    if bp == nil then return nil, "JSON 解析失败: " .. tostring(perr) end
    local ok, errors, warnings = BP.validate(bp)
    return bp, nil, ok, errors, warnings
end

--- 取"下一个"蓝图，循环
function Library.next_entry()
    if #Library.entries == 0 then return nil end
    Library.current = Library.current + 1
    if Library.current > #Library.entries then Library.current = 1 end
    return Library.entries[Library.current], Library.current
end

function Library.current_entry()
    if Library.current < 1 or Library.current > #Library.entries then
        return nil
    end
    return Library.entries[Library.current]
end

function Library.count()
    return #Library.entries
end

--- 列表文字
function Library.list_lines(limit)
    local out = {}
    if #Library.entries == 0 then
        out[#out + 1] = "(库是空的 —— 先按 Y 采集一个基地)"
        return out
    end
    local lim = math.min(#Library.entries, limit or 20)
    for i = 1, lim do
        local e = Library.entries[i]
        local mark = (i == Library.current) and "->" or "  "
        out[#out + 1] = string.format("%s [%d] %s", mark, i, tostring(e.file))
    end
    if #Library.entries > lim then
        out[#out + 1] = string.format("  ... 还有 %d 个", #Library.entries - lim)
    end
    return out
end

return Library
