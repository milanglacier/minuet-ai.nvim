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

## Chat LLMs

For chat models like OpenAI, Claude, and Gemini, repository context can be
incrementally added to the prompt-building process. To achieve this, include an
additional placeholder `{{{repo_context}}}` in the template:

```lua
gemini = {
    model = 'gemini-2.0-flash',
    system = {
        template = '{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}\n{{{repo_context}}}',
        repo_context = [[9. Additional context from other files in the repository will be wrapped in <repo_context> tags. Each file will be separated by <file_separator> tags. Each file will include its relative path and content.]],
    },
    chat_input = {
        template = '{{{repo_context}}}\n{{{language}}}\n{{{tab}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>\n<contextAfterCursor>\n{{{context_after_cursor}}}',
        repo_context = function(pref, suff)
            local prompt_message = ''
            if has_vc then
                local cache_result = vectorcode_cacher.query_from_cache(0)
                num_docs = #cache_result
                for _, file in ipairs(cache_result) do
                    prompt_message = prompt_message
                        .. '<'
                        .. 'file_separator'
                        .. '>'
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

```lua
provider_options = {
    openai_fim_compatible = { -- or codestral
        model = 'qwen-2.5-coder:7b',
        template = {
            prompt = function(pref, suff)
                local prompt_message = ''
                for _, file in ipairs(vectorcode_cacher.query_from_cache(0)) do
                    prompt_message = prompt_message .. '<|file_sep|>' .. file.path .. '\n' .. file.document
                end
                return prompt_message .. '<|fim_prefix|>' .. pref .. '<|fim_suffix|>' .. suff .. '<|fim_middle|>'
            end,
            suffix = false,
        },
    },
}
```

> [!NOTE] Symbols like `<|file_sep|>`, `<|fim_begin|>` are special tokens
> serve as prompt boundaries. Some LLMs, like Qwen2.5-Coder have been trained
> with specific tokens that will help them better understand the prompt
> composition. The [VectorCode
> wiki](https://github.com/Davidyz/VectorCode/wiki/Prompt-Gallery) provides a
> comprehensive list of prompt structures tailored for various LLMs
> (Qwen2.5-coder, deepseek-V3, Codestral, StarCoder2, etc.). Utilizing special
> tokens help the models generate more accurate completions.
