--[[ ============================================================================
  PWKeyTest v0.1 -- 探测这个 UE4SS 版本的热键注册 API

  背景
  ----
  PWRecon 用 `RegisterKeyBind("F7", fn)` 注册失败（错误信息为空）。
  而 Keybinds mod 用的是:
      RegisterKeyBindAsync(Key.J, {ModifierKey.CONTROL}, fn)
  且 FirstPerson 已经弃用 RegisterKeyBind，改用游戏原生 Player Action。

  所以本脚本逐一试探各种签名，把结果打到日志，用来确定正确写法。

  顺序很关键：先探测能力，再注册，避免一次尝试失败就卡死。

  用法: 放到 UE4SS\Mods\PWKeyTest\Scripts\main.lua，在 mods.txt 加 PWKeyTest : 1
============================================================================ ]]

local TAG = "[PWKeyTest]"
local function out(s) print(TAG .. " " .. tostring(s)) end

out("================ API 能力探测 ================")

-- ---------------------------------------------------------------- 全局函数
local globals = {
    "RegisterKeyBind",
    "RegisterKeyBindAsync",
    "IsKeyBindRegistered",
    "Key",
    "ModifierKey",
    "UnregisterKeyBind",
}
for _, name in ipairs(globals) do
    local ok, v = pcall(function() return _ENV[name] end)
    if ok and v ~= nil then
        out(string.format("  %-24s 存在  (%s)", name, type(v)))
    else
        out(string.format("  %-24s 不存在", name))
    end
end

-- 探测 Key 枚举里有哪些键名
out("")
out("---- Key 枚举里的 F 键与常用键 ----")
local wantKeys = { "F1", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
                   "J", "K", "L", "H", "N", "M", "B", "G", "R", "T", "Y", "U" }
if Key ~= nil then
    for _, k in ipairs(wantKeys) do
        local ok, v = pcall(function() return Key[k] end)
        if ok and v ~= nil then
            out(string.format("  Key.%-6s = %s", k, tostring(v)))
        end
    end
else
    out("  Key 为 nil，无法探测")
end

-- ---------------------------------------------------------------- 注册探测
out("")
out("================ 注册签名试探 ================")

local function probe(label, fn)
    local ok, err = pcall(fn)
    if ok then
        out(string.format("  [成功] %s", label))
        return true
    else
        local msg = tostring(err)
        if msg == nil or msg == "" then msg = "(错误信息为空)" end
        -- 只取第一行，避免刷屏
        msg = msg:match("^[^\n]*")
        out(string.format("  [失败] %-52s -> %s", label, msg))
        return false
    end
end

local dummy = function() out("  >>> 热键被按下 <<<") end

-- 候选 1: 字符串键名 + 旧 API（我之前用的写法）
probe('RegisterKeyBind("F7", fn)', function()
    RegisterKeyBind("F7", dummy)
end)

-- 候选 2: Key 枚举 + 旧 API
probe("RegisterKeyBind(Key.F8, fn)", function()
    RegisterKeyBind(Key.F8, dummy)
end)

-- 候选 3: Key 枚举 + 空修饰键表 + 新 API（Keybinds mod 的写法）
probe("RegisterKeyBindAsync(Key.F9, {}, fn)", function()
    RegisterKeyBindAsync(Key.F9, {}, dummy)
end)

-- 候选 4: Key 枚举 + ModifierKey 常量表
probe("RegisterKeyBindAsync(Key.F10, {ModifierKey.CONTROL}, fn)", function()
    RegisterKeyBindAsync(Key.F10, { ModifierKey.CONTROL }, dummy)
end)

-- 候选 5: 字符串 + 新 API
probe('RegisterKeyBindAsync("F11", {}, fn)', function()
    RegisterKeyBindAsync("F11", {}, dummy)
end)

-- ---------------------------------------------------------------- 冲突检测
out("")
out("---- 冲突检测：这些键是否已被占用 ----")
if IsKeyBindRegistered ~= nil and Key ~= nil then
    for _, item in ipairs({ { "F6", Key.F6 }, { "F7", Key.F7 }, { "F8", Key.F8 },
                            { "F9", Key.F9 }, { "F10", Key.F10 }, { "F11", Key.F11 } }) do
        local ok, v = pcall(function() return IsKeyBindRegistered(item[2], {}) end)
        out(string.format("  IsKeyBindRegistered(Key.%-5s, {}) = %s", item[1], ok and tostring(v) or "调用失败"))
    end
end

out("")
out("================ 探测结束 ================")
out("把日志里 [PWKeyTest] 开头的所有行发给我。")
out("若某个签名显示[成功]，我就用那个改 PWRecon。")
