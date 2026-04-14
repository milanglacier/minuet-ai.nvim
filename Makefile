NVIM ?= nvim

.PHONY: test

test:
	$(NVIM) --headless -u NONE -i NONE -n +"lua require('tests.run').run()"
