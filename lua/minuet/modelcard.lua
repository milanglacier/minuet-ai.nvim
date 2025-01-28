-- referenced from https://github.com/sigoden/aichat/blob/main/models.yaml
local M = {}

M.models = {
    openai = {
        'gpt-4o',
        'gpt-3.5-turbo',
        'chatgpt-4o-latest',
        'gpt-4o-mini',
        'o1',
        'o1-mini',
    },
    claude = {
        'claude-3-5-sonnet-20241022',
        'claude-3-5-sonnet-latest',
        'claude-3-5-haiku-latest',
        'claude-3-5-haiku-20241022',
        'claude-3-opus-latest',
        'claude-3-opus-20240229',
    },
    gemini = {
        'gemini-1.5-pro-latest',
        'gemini-1.5-flash-latest',
        'gemini-1.5-flash-8b-latest',
        'gemini-2.0-flash-exp',
        'gemini-2.0-flash-thinking-exp',
        'gemini-exp-1206',
    },
    openai_compatible = {
        deepseek = {
            'deepseek-chat',
            'deepseek-reasoner',
        },
        mistral = {
            'mistral-large-latest',
            'mistral-small-latest',
            'codestral-latest',
            'ministral-8b-latest',
        },
        fireworks = {
            'accounts/fireworks/models/deepseek-r1',
            'accounts/fireworks/models/deepseek-v3',
            'accounts/fireworks/models/llama-v3p2-3b-instruct',
            'accounts/fireworks/models/llama-v3p3-70b-instruct',
            'accounts/fireworks/models/llama-v3p1-8b-instruct',
            'accounts/fireworks/models/qwen2p5-72b-instruct',
            'accounts/fireworks/models/qwen2p5-coder-32b-instruct',
            'accounts/fireworks/models/qwen2p5-coder-32b-instruct',
        },
        groq = {
            'llama-3.3-70b-versatile',
            'gemma2-9b-it',
            'llama-3.1-8b-instant',
            'mixtral-8x7b-32768',
        },
        deepinfra = {
            'meta-llama/Llama-3.3-70B-Instruct-Turbo',
            'meta-llama/Llama-3.3-70B-Instruct',
            'meta-llama/Meta-Llama-3.1-70B-Instruct',
            'meta-llama/Meta-Llama-3.1-8B-Instruct',
            'meta-llama/Meta-Llama-3.1-405B-Instruct',
            'Qwen/Qwen2.5-Coder-32B-Instruct',
            'Qwen/Qwen2.5-72B-Instruct',
            'deepseek-ai/DeepSeek-V3',
        },
        ollama = {
            'deepseek-r1',
            'deepseek-v3',
            'deepseek-v2.5',
            'qwen2.5-coder',
            'qwen2.5',
            'llama-3.3',
            'llama-3.1',
        },
    },
    openai_fim_compatible = {
        deepseek = { 'deepseek-chat' },
        ollama = { 'qwen2.5-coder', 'deepseek-coder-v2', 'deepseek-v2.5', 'deepseek-v3', 'codestral' },
    },
    codestral = { 'codestral-latest' },
}

return M
