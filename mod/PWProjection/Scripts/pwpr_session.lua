--[[ ===========================================================================
  PWPR · session  ——  放置会话（纯状态机，不直接调引擎）

  职责:
    · 记住"当前加载的是哪张蓝图"
    · 记住投影的偏移 / 旋转 / 分层过滤
    · 把"玩家在哪、面朝哪"换算成投影应该放在哪
    · 提供 微调 / 旋转 / 换层 这些操作

  坐标约定:
    投影的放置点 place = { x=, y=, z=, yaw= }  单位【世界厘米 / 度】
    蓝图内部的 p 是以包围盒中心为原点的米制偏移，
    所以"让蓝图底部落在玩家脚下"要写成:
        place.z = 玩家Z + size.z*100/2
=========================================================================== ]]

local Util = require("pwpr_util")
local BP = require("pwpr_bp")

local Session = {}

Session.active = false
Session.bp = nil
Session.bp_file = nil
Session.name = nil

Session.offset = { x = 0.0, y = 0.0, z = 0.0 }   -- 厘米
Session.yaw = 0.0                                 -- 度
Session.layer_mode = "all"                        -- all | single | range
Session.layer_index = 0
Session.step_cm = 100
Session.rot_step = 15.0
Session.anchor = { x = nil, y = nil, z = nil }    -- 最近一次记录的世界位置

local STEP_LADDER = { 10, 50, 100, 500, 1000 }

-- --------------------------------------------------------------------------
-- 玩家位置 / 朝向
-- --------------------------------------------------------------------------

--- 玩家脚下位置（厘米）。拿不到返回 nil
function Session.player_pos()
    local ok, p = pcall(function()
        return require("UEHelpers").GetPlayer()
    end)
    local pawn = ok and Util.unwrap(p) or nil
    if not Util.valid(pawn) then return nil end
    return Util.loc_of(pawn)
end

--- 玩家的朝向（优先用控制器视角，退回角色朝向）
function Session.heading_yaw()
    -- 1) 控制器视角（第三人称下更符合"我看到的方向"）
    local ok, res = pcall(function()
        local pcs = FindAllOf("PlayerController")
        if type(pcs) ~= "table" or #pcs == 0 then return nil end
        local pc = Util.unwrap(pcs[1])
        if not Util.valid(pc) then return nil end
        local rot = pc:GetControlRotation()
        return Util.num(rot, "Yaw")
    end)
    if ok and type(res) == "number" then return res end

    -- 2) 角色朝向
    local ok2, p = pcall(function()
        return require("UEHelpers").GetPlayer()
    end)
    local pawn = ok2 and Util.unwrap(p) or nil
    if Util.valid(pawn) then
        local _, yaw, _ = Util.rot_of(pawn)
        return yaw
    end
    return 0.0
end

--- 玩家"准星"（位置 + 视线方向，单位向量）。
---
--- 干什么用: 蓝图建造模式（`buildsnap_mode = "blueprint"`）要判断
---   "玩家准星指着投影里的哪一件"。
--- ★ 为什么要有 pitch（俯仰）: 投影里的屋顶/二层件在上方，只用水平朝向选不准；
---   控制器视角的 Pitch 正好就是玩家仰头/低头的角度。
---
--- 返回 x,y,z, dirx,diry,dirz；拿不到返回 nil
function Session.aim()
    local x, y, z = Session.player_pos()
    if x == nil then return nil end
    -- 优先用控制器视角（含俯仰）；拿不到就退回角色朝向（水平）
    local pitch, yaw = 0.0, nil
    local ok, res = pcall(function()
        local pcs = FindAllOf("PlayerController")
        if type(pcs) ~= "table" or #pcs == 0 then return nil end
        local pc = Util.unwrap(pcs[1])
        if not Util.valid(pc) then return nil end
        local p, y2, _ = Util.rot_of(pc:GetControlRotation())
        return { p = p, y = y2 }
    end)
    if ok and type(res) == "table" then
        pitch, yaw = res.p, res.y
    end
    if yaw == nil then yaw = Session.heading_yaw() end
    local pr, yr = math.rad(pitch), math.rad(yaw)
    local cp = math.cos(pr)
    -- UE 里 Y 轴向右、Pitch 正 = 抬头
    return x, y, z, cp * math.cos(yr), cp * math.sin(yr), math.sin(pr)
end

--- 前后左右单位向量（水平面）
function Session.basis()
    local yaw = math.rad(Session.heading_yaw())
    local fx, fy = math.cos(yaw), math.sin(yaw)
    -- UE 里 Y 轴向右，所以右向量 = (cos(yaw+90), sin(yaw+90))
    local rx, ry = math.cos(yaw + math.pi * 0.5), math.sin(yaw + math.pi * 0.5)
    return fx, fy, rx, ry
end

-- --------------------------------------------------------------------------
-- 放置点
-- --------------------------------------------------------------------------

--- 玩家"脚底"相对 Actor 原点的距离（厘米，向下为正）
---
--- ★ 为什么需要: Palworld 的角色 Actor 原点在**胶囊体中心**，不是脚底。
---   直接把蓝图铺在 actor 原点高度上，投影就会整层浮在地面上方
---   约半身高（~90 厘米）—— 实测踩过这个（玩家报"建筑都是浮空的"）。
---
--- 优先顺序: 配置手动指定 > 读胶囊体半高 > 默认 90 厘米
function Session.feet_offset_cm()
    local manual = nil
    pcall(function()
        manual = tonumber(require("pwpr_config").get("player_feet_offset_cm"))
    end)
    if manual ~= nil and manual ~= 0 then
        return manual, "配置指定"
    end

    local ok, p = pcall(function()
        return require("UEHelpers").GetPlayer()
    end)
    local pawn = ok and Util.unwrap(p) or nil
    if Util.valid(pawn) then
        local cap = Util.prop(pawn, "CapsuleComponent")
        if cap ~= nil then
            local hh = Util.prop(cap, "CapsuleHalfHeight")
            if type(hh) == "number" and hh > 10 and hh < 500 then
                return hh, "读胶囊体半高"
            end
        end
    end
    return 90.0, "默认值（读不到胶囊体）"
end

--- 计算当前应该在哪个世界位置画投影
function Session.place()
    if Session.anchor.x == nil then
        local x, y, z = Session.player_pos()
        if x == nil then return nil end
        Session.anchor.x, Session.anchor.y, Session.anchor.z = x, y, z
    end
    local size = (Session.bp and Session.bp.meta and Session.bp.meta.size) or {}
    local half_z = (tonumber(size.z) or 0.0) * 100.0 * 0.5
    local feet, why = Session.feet_offset_cm()
    Session.last_feet = { v = feet, why = why }
    return {
        x = Session.anchor.x + Session.offset.x,
        y = Session.anchor.y + Session.offset.y,
        -- 减去脚底偏移: 让蓝图的【底面】落在玩家站立的地面上，而不是半身高处
        z = Session.anchor.z - feet + half_z + Session.offset.z,
        yaw = Session.yaw,
    }
end

--- 脚底偏移的说明文字（用于日志）
function Session.feet_note()
    local f = Session.last_feet
    if f == nil then return "(未计算)" end
    return string.format("%.0f 厘米（%s）", f.v, tostring(f.why))
end

--- 重新吸附到玩家当前位置（清掉偏移）
function Session.resnap()
    local x, y, z = Session.player_pos()
    if x == nil then return false, "拿不到玩家位置" end
    Session.anchor.x, Session.anchor.y, Session.anchor.z = x, y, z
    Session.offset.x, Session.offset.y, Session.offset.z = 0.0, 0.0, 0.0
    return true, nil
end

-- --------------------------------------------------------------------------
-- 微调
-- --------------------------------------------------------------------------

--- axis: "fwd" | "back" | "left" | "right" | "up" | "down"
function Session.nudge(axis)
    local d = Session.step_cm
    local fx, fy, rx, ry = Session.basis()
    if axis == "fwd" then
        Session.offset.x = Session.offset.x + fx * d
        Session.offset.y = Session.offset.y + fy * d
    elseif axis == "back" then
        Session.offset.x = Session.offset.x - fx * d
        Session.offset.y = Session.offset.y - fy * d
    elseif axis == "right" then
        Session.offset.x = Session.offset.x + rx * d
        Session.offset.y = Session.offset.y + ry * d
    elseif axis == "left" then
        Session.offset.x = Session.offset.x - rx * d
        Session.offset.y = Session.offset.y - ry * d
    elseif axis == "up" then
        Session.offset.z = Session.offset.z + d
    elseif axis == "down" then
        Session.offset.z = Session.offset.z - d
    else
        return false
    end
    return true
end

function Session.rotate(sign)
    Session.yaw = Util.norm_yaw(Session.yaw + sign * Session.rot_step)
    return true
end

function Session.next_step()
    local cur = Session.step_cm
    local idx = 1
    for i = 1, #STEP_LADDER do
        if STEP_LADDER[i] == cur then
            idx = i
            break
        end
    end
    idx = idx + 1
    if idx > #STEP_LADDER then idx = 1 end
    Session.step_cm = STEP_LADDER[idx]
    return Session.step_cm
end

function Session.reset_offset()
    Session.offset.x, Session.offset.y, Session.offset.z = 0.0, 0.0, 0.0
    Session.yaw = 0.0
    return true
end

-- --------------------------------------------------------------------------
-- 分层
-- --------------------------------------------------------------------------

function Session.layer_count()
    local meta = Session.bp and Session.bp.meta
    return tonumber(meta and meta.layerCount) or 1
end

--- 循环: all -> 0 -> 1 -> ... -> n-1 -> all
function Session.cycle_layer()
    local n = Session.layer_count()
    if Session.layer_mode ~= "single" then
        Session.layer_mode = "single"
        Session.layer_index = 0
    else
        Session.layer_index = Session.layer_index + 1
        if Session.layer_index >= n then
            Session.layer_mode = "all"
            Session.layer_index = 0
        end
    end
    return Session.layer_mode, Session.layer_index
end

function Session.layer_label()
    if Session.layer_mode == "single" then
        return string.format("仅第 %d 层 / 共 %d 层",
            Session.layer_index, Session.layer_count())
    end
    return string.format("全部层 / 共 %d 层", Session.layer_count())
end

-- --------------------------------------------------------------------------
-- 载入 / 卸载
-- --------------------------------------------------------------------------

function Session.activate(bp, file)
    if type(bp) ~= "table" then return false, "蓝图无效" end
    Session.bp = bp
    Session.bp_file = file
    Session.name = (bp.meta and bp.meta.name) or file or "?"
    Session.active = true
    Session.reset_offset()
    Session.layer_mode = "all"
    Session.layer_index = 0
    Session.anchor = { x = nil, y = nil, z = nil }
    return true, nil
end

function Session.deactivate()
    Session.active = false
    Session.bp = nil
    Session.bp_file = nil
    Session.name = nil
    Session.anchor = { x = nil, y = nil, z = nil }
    return true
end

function Session.status_lines()
    local out = {}
    if not Session.active or Session.bp == nil then
        out[#out + 1] = "当前蓝图: (未加载)"
        return out
    end
    local size = (Session.bp.meta and Session.bp.meta.size) or {}
    out[#out + 1] = string.format("当前蓝图: %s   (%s)",
        tostring(Session.name), tostring(Session.bp_file))
    out[#out + 1] = string.format("  尺寸 %.1f x %.1f x %.1f 米   件数 %s",
        tonumber(size.x) or 0, tonumber(size.y) or 0, tonumber(size.z) or 0,
        tostring(Session.bp.meta and Session.bp.meta.total or "?"))
    out[#out + 1] = string.format("  分层 %s", Session.layer_label())
    out[#out + 1] = string.format("  偏移 (%.0f, %.0f, %.0f) 厘米   旋转 %.0f 度   步长 %d 厘米",
        Session.offset.x, Session.offset.y, Session.offset.z,
        Session.yaw, Session.step_cm)
    return out
end

--- 一行短摘要: 偏移 / 旋转 / 步长
---
--- ★ 为什么单独给一行: 微调是"按一下要看一下"的操作，
---   屏幕提示那一行要能一眼看出"现在偏到哪了"，
---   而 Session.status_lines() 是给 F7 用的多行详细版，太长。
function Session.offset_note()
    if Session.yaw ~= 0.0 then
        return string.format("偏移(%.0f,%.0f,%.0f) 旋转 %.0f°",
            Session.offset.x, Session.offset.y, Session.offset.z, Session.yaw)
    end
    return string.format("偏移(%.0f,%.0f,%.0f)",
        Session.offset.x, Session.offset.y, Session.offset.z)
end

--- 渲染过滤参数（给 Ghost.fill 用）
function Session.filter()
    if Session.layer_mode == "single" then
        return "single", Session.layer_index, nil, nil
    end
    return "all", nil, nil, nil
end

return Session
