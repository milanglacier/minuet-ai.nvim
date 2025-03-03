# Launching the llama.cpp Server: Example Script

This guide provides several configuration variants for the `qwen2.5-coder`
based on local computing power, specifically the available VRAM.

### **For Systems with More Than 16GB VRAM**

```bash
llama-server \
    -hf ggml-org/Qwen2.5-Coder-7B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

### **For Systems with Less Than 16GB VRAM**

```bash
llama-server \
    -hf ggml-org/Qwen2.5-Coder-3B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

### **For Systems with Less Than 8GB VRAM**

```bash
llama-server \
    -hf ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

## Example minuet config

```lua
require('minuet').setup {
    provider = 'openai_fim_compatible',
    n_completions = 1, -- recommend for local model for resource saving
    -- I recommend beginning with a small context window size and incrementally
    -- expanding it, depending on your local computing power. A context window
    -- of 512, serves as an good starting point to estimate your computing
    -- power. Once you have a reliable estimate of your local computing power,
    -- you should adjust the context window to a larger value.
    context_window = 512,
    provider_options = {
        openai_fim_compatible = {
            api_key = 'TERM',
            name = 'Llama.cpp',
            end_point = 'http://localhost:8012/v1/completions',
            -- The model is set by the llama-cpp server and cannot be altered
            -- post-launch.
            model = 'PLACEHOLDER',
            optional = {
                max_tokens = 56,
                top_p = 0.9,
            },
            -- Llama.cpp does not support the `suffix` option in FIM completion.
            -- Therefore, we must disable it and manually populate the special
            -- tokens required for FIM completion.
            template = {
                prompt = function(context_before_cursor, context_after_cursor)
                    return '<|fim_prefix|>'
                        .. context_before_cursor
                        .. '<|fim_suffix|>'
                        .. context_after_cursor
                        .. '<|fim_middle|>'
                end,
                suffix = false,
            },
        },
    },
}
```

## **Acknowledgment**

- [llama.vim](https://github.com/ggml-org/llama.vim): A reference for CLI parameters used in launching the `llama.cpp` server.

# Integration with VectorCode

For a project indexed by
[VectorCode](https://github.com/Davidyz/VectorCode/blob/main/docs/cli.md), you
can incorporate the query results into the prompt. Subsequently, while working
on a buffer registered with
[VectorCode](https://github.com/Davidyz/VectorCode/blob/main/docs/neovim.md#user-command),
the system will automatically integrate relevant files from the repository into
the prompt, enhancing completion results. This retrieval process occurs locally
on your machine, though you may opt to utilize a hosted embedding model or
database provider if desired.

Note that `minuet.config.context_window` controls only the context window
before and after the cursor; it does not affect the data returned by
VectorCode, as that information is external and not managed by Minuet. If
needed, consider limiting the context size on your side.

This recipe demonstrates a basic setup of `VectorCode`. For comprehensive
configuration options, please consult the [official VectorCode
documentation](https://github.com/Davidyz/VectorCode/blob/main/docs/neovim.md).

## Chat LLMs

For chat models like OpenAI, Claude, and Gemini, repository context can be
incrementally added to the prompt-building process. To achieve this, include an
additional placeholder `{{{repo_context}}}` in the template:

Firstly, type `:VectorCode register`, this command sets the autocmd to
periodically update RAG queries for the current buffer you are editing.

```lua

require("vectorcode").setup({
    -- number of retrieved documents
    n_query = 1,
})
local has_vc, vectorcode_config = pcall(require, "vectorcode.config")
local vectorcode_cacher = nil
if has_vc then
    vectorcode_cacher = vectorcode_config.get_cacher_backend()
end

gemini = {
    model = 'gemini-2.0-flash',
    system = {
        template = '{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}\n{{{repo_context}}}',
        repo_context = [[9. Additional context from other files in the repository will be enclosed in <repo_context> tags. Each file will be separated by <file_separator> tags, containing its relative path and content.]],
    },
    chat_input = {
        template = '{{{repo_context}}}\n{{{language}}}\n{{{tab}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>\n<contextAfterCursor>\n{{{context_after_cursor}}}',
        repo_context = function(_, _, _)
            local prompt_message = ''
            if has_vc then
                local cache_result = vectorcode_cacher.query_from_cache(0)
                for _, file in ipairs(cache_result) do
                    prompt_message = prompt_message
                        .. '<file_separator>'
                        .. file.path
                        .. '\n'
                        .. file.document
                end
            end
            if prompt_message ~= '' then
                prompt_message = '<repo_context>\n' .. prompt_message .. '\n</repo_context>'
            end
            return prompt_message
        end,
    },
}
```

## FIM LLMs

For FIM-compatible backends such as [Codestral](#codestral) and
[openai_fim_compatible](#openai-fim-compatible), the LLM prompt construction
utilizes the `prompt` and `suffix` parameters. These parameters typically
represent the text before and after the cursor position, respectively. The LLM
server generates the final prompt by combining its template with the provided
input. The
[qwen-2.5-coder](https://ollama.com/library/qwen2.5-coder/blobs/e94a8ecb9327)
from Ollama serves as an example of such a template.

To incorporate repository context while maintaining FIM compatibility, set
`suffix` to `false`. This configuration directs the LLM server to use the
`prompt` parameter's content directly, bypassing the default template
construction process. This approach prevents potential conflicts with FIM
completion functionality that might arise when special tokens are
inappropriately populated by the template. When configuring the `prompt`
function in this way, you can include:

- Repository context
- Prefix text
- Suffix text
- Any additional context required for the LLM

Firstly, type `:VectorCode regiester`, this command starts the timer to
periodically update RAG queries for the current buffer you are editing.

```lua
require("vectorcode").setup({
    -- number of retrieved documents
    n_query = 1,
})
local has_vc, vectorcode_config = pcall(require, "vectorcode.config")
local vectorcode_cacher = nil
if has_vc then
    vectorcode_cacher = vectorcode_config.get_cacher_backend()
end

provider_options = {
    openai_fim_compatible = { -- or codestral
        model = 'qwen-2.5-coder:7b',
        template = {
            prompt = function(pref, suff)
                local prompt_message = ''
                if has_vc then
                    for _, file in ipairs(vectorcode_cacher.query_from_cache(0)) do
                        prompt_message = prompt_message .. '<|file_sep|>' .. file.path .. '\n' .. file.document
                    end
                end
                return prompt_message .. '<|fim_prefix|>' .. pref .. '<|fim_suffix|>' .. suff .. '<|fim_middle|>'
            end,
            suffix = false,
        },
    },
}
```

> [!NOTE]
> Symbols like `<|file_sep|>`, `<|fim_begin|>` are special tokens
> serve as prompt boundaries. Some LLMs, like Qwen2.5-Coder have been trained
> with specific tokens that will help them better understand the prompt
> composition. The [VectorCode
> wiki](https://github.com/Davidyz/VectorCode/wiki/Prompt-Gallery) provides a
> comprehensive list of prompt structures tailored for various LLMs
> (Qwen2.5-coder, deepseek-V3, Codestral, StarCoder2, etc.). Utilizing special
> tokens help the models generate more accurate completions.
