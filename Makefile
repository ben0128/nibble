SOURCES := $(wildcard Sources/*.swift)
PREFIX ?= /usr/local
APP := Nibble.app

nibble: $(SOURCES)
	swiftc -O -swift-version 5 $(SOURCES) -o nibble
	@echo "binary: $$(du -h nibble | cut -f1)"

# .app bundle：雙擊啟動選單列模式，並解鎖需要 bundle 的功能（通知、登入項）
app: nibble
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp nibble $(APP)/Contents/MacOS/nibble
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --deep --sign - $(APP) 2>/dev/null || true
	@echo "bundle: $$(du -sh $(APP) | cut -f1) → 拖進 /Applications 或 open $(APP)"

install: nibble
	install -d $(PREFIX)/bin
	install -m 755 nibble $(PREFIX)/bin/nibble
	@echo "installed: $(PREFIX)/bin/nibble"

uninstall:
	rm -f $(PREFIX)/bin/nibble

clean:
	rm -f nibble
	rm -rf $(APP)

.PHONY: app install uninstall clean
