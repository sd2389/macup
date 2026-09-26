# Common tasks. `make install` puts the `macup` command in ~/.local/bin;
# override with `make install PREFIX=/usr/local` (may need sudo).
PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: build install uninstall test app

build:
	swift build -c release --product macup

install: build
	install -d "$(BINDIR)"
	install -m 755 "$$(swift build -c release --show-bin-path)/macup" "$(BINDIR)/macup"
	@echo "Installed $(BINDIR)/macup"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "Add $(BINDIR) to your PATH to run macup from anywhere.";; esac

uninstall:
	rm -f "$(BINDIR)/macup"

test:
	scripts/test.sh

app:
	scripts/build-app.sh
