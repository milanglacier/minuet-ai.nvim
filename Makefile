NVIM ?= nvim
STYLUA ?= stylua

.PHONY: test format format-check

test:
	$(NVIM) --headless -u NONE -i NONE -n +"lua require('tests.run').run()"

format:
	$(STYLUA) lua/ tests/

format-check:
	$(STYLUA) --check lua/ tests/
