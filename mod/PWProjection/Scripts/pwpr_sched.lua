--[[ ===========================================================================
  PWPR · sched  ——  把工作丢回游戏线程

  为什么需要:
    热键回调不一定在游戏线程上执行。对"只读"操作（FindAllOf / 读坐标）
    实测直接跑没问题（PWRecon 长期如此），但【创建/修改对象】必须回到
    游戏线程，否则就是在和引擎的 tick 抢资源 —— 这类事情正是前几次
    访问违例崩溃的成因。

    这个 UE4SS 版本确认提供（SBB 在用）:
      ExecuteInGameThread(fn)
      ExecuteInGameThreadWithDelay(delay_ms, fn)
      ExecuteWithDelay(delay_ms, fn)

  降级策略: 调度器不存在 -> 直接执行（只读操作已验证这样是安全的）。
=========================================================================== ]]

local Sched = {}

Sched.has_game_thread = false
Sched.has_game_thread_delay = false
Sched.last_route = "unknown"

function Sched.detect()
    Sched.has_game_thread = type(ExecuteInGameThread) == "function"
    Sched.has_game_thread_delay =
        type(ExecuteInGameThreadWithDelay) == "function"
    return Sched.has_game_thread or Sched.has_game_thread_delay
end

--- 在游戏线程上执行 fn。fn 内部必须自己 pcall（本函数只是调度）
function Sched.game_thread(fn, delay_ms)
    if type(fn) ~= "function" then return false end
    local delay = tonumber(delay_ms) or 0

    if Sched.has_game_thread_delay then
        local ok = pcall(function()
            ExecuteInGameThreadWithDelay(delay, fn)
        end)
        if ok then
            Sched.last_route = "ExecuteInGameThreadWithDelay"
            return true
        end
    end
    if Sched.has_game_thread then
        local ok = pcall(function()
            ExecuteInGameThread(fn)
        end)
        if ok then
            Sched.last_route = "ExecuteInGameThread"
            return true
        end
    end
    -- 都没有：直接跑（调用方要保证 fn 自己是安全的）
    Sched.last_route = "inline"
    pcall(fn)
    return false
end

function Sched.describe()
    return string.format("调度: game_thread=%s delay=%s 实际走 %s",
        tostring(Sched.has_game_thread),
        tostring(Sched.has_game_thread_delay),
        tostring(Sched.last_route))
end

return Sched
