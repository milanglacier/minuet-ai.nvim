NVIM ?= nvim
STYLUA ?= stylua

.PHONY: test format format-check benchmark

test:
	$(NVIM) --headless -u NONE -i NONE -n +"lua require('tests.run').run()"

benchmark:
	$(NVIM) --headless -u NONE -i NONE --cmd "set noswapfile" +"luafile tests/duet_edits_bench.lua" +"qa!"

format:
	$(STYLUA) lua/ tests/

format-check:
	$(STYLUA) --check lua/ tests/
