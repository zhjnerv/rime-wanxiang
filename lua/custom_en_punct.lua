-- lua/custom_en_punct.lua
-- 独立英文半角标点处理器 (增强版)
-- 1. 拦截纯英文单词上屏后的下一个标点符号，防止转换为全角字符。
-- 2. 智能处理网址输入：在输入框内为纯英文且无中文候选时，按点号(.)不上屏，而是作为字符进入输入框。

local P = {}

local allowed_ascii_symbols = {
    [32] = true,  -- space
    [33] = true,  -- !
    [39] = true,  -- ' 
    [44] = true,  -- ,
    [45] = true,  -- -
    [43] = true,  -- +
    [46] = true,  -- .
    [63] = true,  -- ?
    [92] = true,  -- \
    [48]=true, [49]=true, [50]=true, [51]=true, [52]=true,
    [53]=true, [54]=true, [55]=true, [56]=true, [57]=true,
}

local function is_ascii_phrase_fast(s)
    if not s or s == "" then return false end
    local len = #s
    for i = 1, len do
        local b = string.byte(s, i)
        local is_upper = (b >= 65 and b <= 90)
        local is_lower = (b >= 97 and b <= 122)
        local is_allowed_sym = allowed_ascii_symbols[b]
        if not (is_upper or is_lower or is_allowed_sym) then
            return false
        end
    end
    return true
end

function P.init(env)
    local context = env.engine.context
    env.en_punct_active = false
    
    env.commit_notifier = context.commit_notifier:connect(function(ctx)
        local text = ctx:get_commit_text()
        if text and text ~= "" then
            local text_no_space = string.gsub(text, "%s", "")
            if is_ascii_phrase_fast(text_no_space) then
                env.en_punct_active = true
            else
                env.en_punct_active = false
            end
        end
    end)
end

function P.fini(env)
    if env.commit_notifier then
        env.commit_notifier:disconnect()
    end
end

function P.func(key, env)
    local context = env.engine.context
    local kc = key.keycode
    
    -- 智能网址输入补丁：在 composing 状态下拦截点号
    if kc == 46 and not key:release() and context:is_composing() then
        local input = context.input
        -- 检查当前输入是否全是字母/数字 (看起来像网址前缀)
        if input:match("^[A-Za-z0-9]+$") then
            -- 如果没有候选词，或者是纯英文候选，则将点号推入输入框
            local cand = context:get_selected_candidate()
            if not cand or is_ascii_phrase_fast(cand.text) then
                context:push_input(".")
                env.en_punct_active = false -- 既然手动处理了，重置状态
                return 1 -- kAccepted
            end
        end
    end

    if not env.en_punct_active or key:release() then
        return 2 -- kNoop
    end

    -- Intercept punctuation after a commit of English text
    if (kc >= 33 and kc <= 47) or
       (kc >= 58 and kc <= 64) or
       (kc >= 91 and kc <= 96) or
       (kc >= 123 and kc <= 126) then
        
        env.engine:commit_text(string.char(kc))
        env.en_punct_active = false
        return 1 -- kAccepted
    end

    -- If another printable/functional key is pressed, reset active state
    if (kc >= 48 and kc <= 57) or (kc >= 65 and kc <= 90) or (kc >= 97 and kc <= 122) or kc == 32 or kc == 0xff0d or kc == 13 or kc == 0xff08 then
        env.en_punct_active = false
    end

    return 2 -- kNoop
end

return P
