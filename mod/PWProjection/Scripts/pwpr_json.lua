--[[ ===========================================================================
  PWPR · json  ——  纯 Lua 的 JSON 编解码（不依赖任何引擎功能）

  为什么自己写:
    UE4SS 不带 json 库；蓝图文件既要能读也要能写，而且要能在离线环境里
    被 Python 工具（tools/blueprint.py）交叉验证，所以格式必须标准。

  数组 / 对象的区分:
    Lua 表没有"空数组"的表达能力，所以约定：
      · Json.array(t)  打标记，强制编码成 []
      · 其余情况：键全是 1..n 连续整数 -> 数组，否则 -> 对象
      · 空表默认编码成 {}
=========================================================================== ]]

local Json = {}

local ARRAY_MARK = { __pwpr_json_array = true }

--- JSON null 的哨兵。用独立对象而不是 nil ——
--- 因为 Lua 表里存不了 nil，数组中间出现 null 会导致索引塌陷。
Json.NULL = setmetatable({}, {
    __tostring = function() return "null" end,
})

--- 打上"这是数组"的标记（用于空数组或强制数组）
function Json.array(t)
    t = t or {}
    return setmetatable(t, ARRAY_MARK)
end

function Json.is_array_marked(t)
    local mt = getmetatable(t)
    return mt ~= nil and mt.__pwpr_json_array == true
end

-- --------------------------------------------------------------------------
-- 编码
-- --------------------------------------------------------------------------

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
    s = s:gsub('[%z\1-\31"\\]', function(c)
        local e = ESCAPES[c]
        if e then return e end
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

local function encode_number(n)
    if n ~= n then return "null" end                       -- NaN
    if n == math.huge or n == -math.huge then return "null" end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    local s = string.format("%.6f", n)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    if s == "-0" then s = "0" end
    return s
end

local function is_plain_array(t)
    if Json.is_array_marked(t) then return true end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        if k < 1 or k ~= math.floor(k) then return false end
        if k > n then n = k end
    end
    if n == 0 then return false end        -- 空表 -> {}
    return n == (function()
        local c = 0
        for _ in pairs(t) do c = c + 1 end
        return c
    end)()
end

local encode_value

local function encode_table(t, out)
    if is_plain_array(t) then
        out[#out + 1] = "["
        for i = 1, #t do
            if i > 1 then out[#out + 1] = "," end
            encode_value(t[i], out)
        end
        out[#out + 1] = "]"
        return
    end
    out[#out + 1] = "{"
    local first = true
    -- 排序键，输出稳定（便于 diff 和人工阅读）
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    for i = 1, #keys do
        local k = keys[i]
        local v = t[k]
        if v ~= nil then
            if not first then out[#out + 1] = "," end
            first = false
            out[#out + 1] = encode_string(tostring(k))
            out[#out + 1] = ":"
            encode_value(v, out)
        end
    end
    out[#out + 1] = "}"
end

encode_value = function(v, out)
    local tv = type(v)
    if v == nil or v == Json.NULL then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        out[#out + 1] = encode_number(v)
    elseif tv == "string" then
        out[#out + 1] = encode_string(v)
    elseif tv == "table" then
        encode_table(v, out)
    else
        out[#out + 1] = "null"
    end
end

--- pretty: 缩进美化（默认 true）
function Json.encode(value, pretty)
    local out = {}
    encode_value(value, out)
    local raw = table.concat(out)
    if pretty == false then return raw end
    return Json.prettify(raw)
end

--- 把紧凑 JSON 美化（字符串内的括号不受影响）。
--- 空容器 {} / [] 原样输出，不换行 —— 所以 "{" 只在非空时才增加缩进，
--- 与 "}" 的减缩进严格配对。
function Json.prettify(text)
    local out = {}
    local depth = 0
    local in_str, esc = false, false
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if in_str then
            out[#out + 1] = c
            if esc then esc = false
            elseif c == "\\" then esc = true
            elseif c == '"' then in_str = false end
            i = i + 1
        elseif c == '"' then
            in_str = true
            out[#out + 1] = c
            i = i + 1
        elseif c == "{" or c == "[" then
            local close = (c == "{") and "}" or "]"
            if text:sub(i + 1, i + 1) == close then
                out[#out + 1] = c
                out[#out + 1] = close
                i = i + 2
            else
                depth = depth + 1
                out[#out + 1] = c
                out[#out + 1] = "\n" .. string.rep("  ", depth)
                i = i + 1
            end
        elseif c == "}" or c == "]" then
            depth = depth - 1
            out[#out + 1] = "\n" .. string.rep("  ", depth) .. c
            i = i + 1
        elseif c == "," then
            out[#out + 1] = ","
            out[#out + 1] = "\n" .. string.rep("  ", depth)
            i = i + 1
        elseif c == ":" then
            out[#out + 1] = ": "
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- --------------------------------------------------------------------------
-- 解码
-- --------------------------------------------------------------------------

local function decode_error(text, pos, msg)
    local line = 1
    for _ in text:sub(1, pos):gmatch("\n") do line = line + 1 end
    return nil, string.format("JSON 解析错误(行 %d, 位置 %d): %s", line, pos, msg)
end

local function utf8_from_codepoint(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40),
                           0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + (math.floor(cp / 0x1000) % 0x40),
                       0x80 + (math.floor(cp / 0x40) % 0x40),
                       0x80 + (cp % 0x40))
end

local function skip_ws(text, pos)
    local _, e = text:find("^[ \t\r\n]*", pos)
    return (e or pos - 1) + 1
end

local parse_value

local function parse_string(text, pos)
    -- pos 指向开引号
    local buf = {}
    local i = pos + 1
    while true do
        local c = text:sub(i, i)
        if c == "" then return decode_error(text, i, "字符串未闭合") end
        if c == '"' then
            return table.concat(buf), i + 1
        end
        if c == "\\" then
            local e = text:sub(i + 1, i + 1)
            if e == "u" then
                local hex = text:sub(i + 2, i + 5)
                local cp = tonumber(hex, 16)
                if cp == nil then
                    return decode_error(text, i, "非法的 \\u 转义")
                end
                i = i + 6
                -- 代理对
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local hex2 = text:sub(i + 2, i + 5)
                    local lo = tonumber(hex2, 16)
                    if text:sub(i, i + 1) == "\\u" and lo
                        and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        i = i + 6
                    end
                end
                buf[#buf + 1] = utf8_from_codepoint(cp)
            else
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                              b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                local ch = map[e]
                if ch == nil then
                    return decode_error(text, i, "非法的转义 \\" .. tostring(e))
                end
                buf[#buf + 1] = ch
                i = i + 2
            end
        else
            -- 整段拷贝，比逐字符快很多
            local j = text:find('["\\]', i)
            if j == nil then return decode_error(text, i, "字符串未闭合") end
            buf[#buf + 1] = text:sub(i, j - 1)
            i = j
        end
    end
end

local function parse_number(text, pos)
    local s, e = text:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if s == nil then return decode_error(text, pos, "非法的数字") end
    local raw = text:sub(s, e)
    local n = tonumber(raw)
    if n == nil then return decode_error(text, pos, "非法的数字: " .. raw) end
    return n, e + 1
end

local function parse_array(text, pos)
    local arr = Json.array({})
    local i = skip_ws(text, pos + 1)
    if text:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local v, ni = parse_value(text, i)
        if ni == nil then return nil, nil end
        arr[#arr + 1] = v
        i = skip_ws(text, ni)
        local c = text:sub(i, i)
        if c == "," then
            i = skip_ws(text, i + 1)
        elseif c == "]" then
            return arr, i + 1
        else
            return decode_error(text, i, "数组里期望 , 或 ]")
        end
    end
end

local function parse_object(text, pos)
    local obj = {}
    local i = skip_ws(text, pos + 1)
    if text:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        if text:sub(i, i) ~= '"' then
            return decode_error(text, i, "对象的键必须是字符串")
        end
        local key, ni = parse_string(text, i)
        if key == nil then return nil, ni end
        i = skip_ws(text, ni)
        if text:sub(i, i) ~= ":" then
            return decode_error(text, i, "键后面期望 :")
        end
        i = skip_ws(text, i + 1)
        local v, ni2 = parse_value(text, i)
        if ni2 == nil then return nil, nil end
        obj[key] = v
        i = skip_ws(text, ni2)
        local c = text:sub(i, i)
        if c == "," then
            i = skip_ws(text, i + 1)
        elseif c == "}" then
            return obj, i + 1
        else
            return decode_error(text, i, "对象里期望 , 或 }")
        end
    end
end

parse_value = function(text, pos)
    local c = text:sub(pos, pos)
    if c == "{" then return parse_object(text, pos) end
    if c == "[" then return parse_array(text, pos) end
    if c == '"' then return parse_string(text, pos) end
    if c == "t" and text:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    end
    if c == "f" and text:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    end
    if c == "n" and text:sub(pos, pos + 3) == "null" then
        return Json.NULL, pos + 4
    end
    if c == "" then return decode_error(text, pos, "内容意外结束") end
    return parse_number(text, pos)
end

--- 返回 值 或 nil, 错误信息
--- 解析**一个** JSON 值（严格: 整个文件只能有这一个值）
function Json.decode(text)
    local values, err = Json.decode_multi(text)
    if values == nil then return nil, err end
    if #values ~= 1 then
        return nil, string.format(
            "文件里有 %d 个顶层 JSON 值（应该只有一个对象）", #values)
    end
    return values[1]
end

--- 解析**一到多个** JSON 值（宽松: 允许文件里不小心写了两个 `{}`）。
---
--- ★ 为什么要有它（2026-09-29 玩家实测踩的坑）:
---   配置文件本来是"一个 JSON 对象"，但玩家往里加自定义键时**另起了一个 `{}`**，
---   于是 `Json.decode` 报"末尾有多余内容" ⇒ **整份配置被当成解析失败、全部退回默认值**
---   （连 `ghost_enabled` 都掉回 false，投影直接锁上）—— 玩家只会看到"我的配置没生效"。
---   ⇒ 现在允许多个顶层对象，由调用方合并；同时**大声提示**写法不对。
--- 返回 values(数组), 错误, 多出来的第一个值的序号（没有则为 nil）
function Json.decode_multi(text)
    if type(text) ~= "string" then return nil, "输入不是字符串", nil end
    text = text:gsub("^\239\187\191", "")
    local values = {}
    local pos = skip_ws(text, 1)
    if pos > #text then return nil, "内容为空", nil end
    local extra_index = nil
    while pos <= #text do
        local v, ni = parse_value(text, pos)
        if v == nil and ni == nil then
            if #values == 0 then return nil, "解析失败", nil end
            extra_index = #values
            break
        end
        values[#values + 1] = v
        pos = skip_ws(text, ni)
        if pos <= #text and #values >= 1 and extra_index == nil then
            extra_index = #values
        end
    end
    if #values == 0 then return nil, "解析失败", nil end
    return values, nil, extra_index
end

return Json
