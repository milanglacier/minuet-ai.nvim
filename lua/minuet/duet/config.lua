local default_prompt = [[
You are an AI editing engine that rewrites only the editable region in a document.

Input markers:
- `<editable_region_start>` and `<editable_region_end>` wrap the editable region.
- `<cursor_position>` marks the current cursor position inside that editable region.
]]

local default_guidelines = [[
Guidelines:
1. Return only the rewritten editable region, wrapped in `<editable_region_start>` and `<editable_region_end>`.
2. Include exactly one `<cursor_position>` marker inside the rewritten editable region.
3. Preserve indentation, formatting, and surrounding syntax conventions.
4. Do not return explanations, markdown fences, or any content outside the editable region block.
5. Make the rewrite coherent with the surrounding non-editable text.
]]

local default_system = {
    template = '{{{prompt}}}\n{{{guidelines}}}',
    prompt = default_prompt,
    guidelines = default_guidelines,
}

local default_chat_input = {
    template = table.concat({
        '{{{non_editable_region_before}}}',
        '<editable_region_start>',
        '{{{editable_region_before_cursor}}}<cursor_position>{{{editable_region_after_cursor}}}',
        '<editable_region_end>',
        '{{{non_editable_region_after}}}',
    }, '\n'),
}

local default_few_shots = {
    {
        role = 'user',
        content = table.concat({
            'type User = {',
            '    id: string;',
            '    name: string;',
            '    role?: string;',
            '    active?: boolean;',
            '};',
            '',
            'async function buildRequest(user: User, overrides: Record<string, any> = {}) {',
            "    const baseHeaders = { 'content-type': 'application/json' };",
            '',
            '<editable_region_start>',
            '    const payload = {',
            '        id: user.id,',
            '        name: user.name,',
            '    };',
            '',
            '    return {',
            "        method: 'POST',",
            '        headers: baseHeaders,',
            '        body: JSON.stringify(payload<cursor_position>),',
            '    };',
            '<editable_region_end>',
            '}',
            '',
            'export async function sendUser(user: User, overrides = {}) {',
            '    const request = await buildRequest(user, overrides);',
            "    return fetch('/api/users', request);",
            '}',
        }, '\n'),
    },
    {
        role = 'assistant',
        content = table.concat({
            '<editable_region_start>',
            '    const payload = {',
            '        id: user.id,',
            '        name: user.name,',
            '        role: overrides.role ?? user.role ?? "viewer",',
            '        active: overrides.active ?? user.active ?? true,',
            '    };',
            '',
            '    return {',
            "        method: 'POST',",
            '        headers: {',
            '            ...baseHeaders,',
            '            ...overrides.headers,',
            '        },',
            '        body: JSON.stringify(payload),',
            '        signal: overrides.signal,',
            '        keepalive: overrides.keepalive ?? false,<cursor_position>',
            '    };',
            '<editable_region_end>',
        }, '\n'),
    },
}

local function make_openai_options()
    return {
        model = 'gpt-5.4-mini',
        api_key = 'OPENAI_API_KEY',
        end_point = 'https://api.openai.com/v1/chat/completions',
        system = vim.deepcopy(default_system),
        few_shots = vim.deepcopy(default_few_shots),
        chat_input = vim.deepcopy(default_chat_input),
        optional = {},
        transform = {},
    }
end

local function make_claude_options()
    return {
        model = 'claude-haiku-4-5',
        api_key = 'ANTHROPIC_API_KEY',
        end_point = 'https://api.anthropic.com/v1/messages',
        system = vim.deepcopy(default_system),
        few_shots = vim.deepcopy(default_few_shots),
        chat_input = vim.deepcopy(default_chat_input),
        max_tokens = 8192,
        optional = {},
        transform = {},
    }
end

local function make_gemini_options()
    return {
        model = 'gemini-2.0-flash',
        api_key = 'GEMINI_API_KEY',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        system = vim.deepcopy(default_system),
        few_shots = vim.deepcopy(default_few_shots),
        chat_input = vim.deepcopy(default_chat_input),
        optional = {},
        transform = {},
    }
end

local function make_openai_compatible_options()
    return {
        model = 'mistralai/devstral-small',
        api_key = 'OPENROUTER_API_KEY',
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        name = 'Openrouter',
        system = vim.deepcopy(default_system),
        few_shots = vim.deepcopy(default_few_shots),
        chat_input = vim.deepcopy(default_chat_input),
        optional = {},
        transform = {},
    }
end

---@class minuet.DuetChatInput
---@field template string

---@class minuet.DuetConfig
---@field provider string
---@field request_timeout integer
---@field editable_region { lines_before: integer, lines_after: integer }
---@field preview { enabled: boolean }
---@field provider_options table<string, table>
local M = {
    provider = 'openai',
    request_timeout = 15,
    editable_region = {
        lines_before = 8,
        lines_after = 8,
    },
    preview = {
        enabled = true,
    },
    provider_options = {
        openai = make_openai_options(),
        claude = make_claude_options(),
        gemini = make_gemini_options(),
        openai_compatible = make_openai_compatible_options(),
    },
}

return M
