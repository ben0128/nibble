SOURCES := $(wildcard Sources/*.swift)
PREFIX ?= /usr/local
APP := Nibble.app
APP_DEST ?= /Applications
# 有這個自簽身分就用它簽名，產出正常封印的 bundle（ad-hoc 只是佔位）。
# 注意：這仍然救不了「輔助使用」授權——macOS 對無法串到信任根的憑證是綁 cdhash，
# 重建就要重新授權，除非改用 Apple Developer ID。建立方式見 README 的 Development。
SIGN_ID ?= Nibble Dev

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
	@xattr -cr $(APP)   # Finder 屬性會讓 codesign 拒簽（"detritus not allowed"）
	@codesign --force --deep --sign "$(SIGN_ID)" $(APP) 2>/dev/null \
		&& echo "signed with: $(SIGN_ID)" \
		|| { codesign --force --deep --sign - $(APP) 2>/dev/null; \
		     echo "signed ad-hoc"; }
	@echo "bundle: $$(du -sh $(APP) | cut -f1)"

# 裝到 /Applications：路徑穩定，權限授權給這一份，repo 裡怎麼重建都不影響
install-app: app
	@pkill -f "$(APP)/Contents/MacOS/nibble" 2>/dev/null \
		&& { echo "quit running Nibble"; sleep 1; } || true
	rm -rf "$(APP_DEST)/$(APP)"
	ditto $(APP) "$(APP_DEST)/$(APP)"   # ditto 保留簽名封印，cp -R 會弄壞
	@xattr -cr "$(APP_DEST)/$(APP)"     # 複製過程又會沾上 FinderInfo，清掉才過得了 --strict
	@codesign --verify --deep --strict "$(APP_DEST)/$(APP)" && echo "installed & verified: $(APP_DEST)/$(APP)"

install: nibble
	install -d $(PREFIX)/bin
	install -m 755 nibble $(PREFIX)/bin/nibble
	@echo "installed: $(PREFIX)/bin/nibble"

uninstall:
	-launchctl bootout gui/$$(id -u)/com.ben0128.nibble.replay 2>/dev/null
	rm -f ~/Library/LaunchAgents/com.ben0128.nibble.replay.plist
	rm -f ~/.config/nibble/menubar.lock ~/.config/nibble/engine.json
	rm -f $(PREFIX)/bin/nibble
	rm -rf "$(APP_DEST)/$(APP)"
	@echo "kept: ~/.config/nibble.json and ~/.config/nibble/backups (your settings and onboard dumps)"

clean:
	rm -f nibble
	rm -rf $(APP)

.PHONY: app install-app install uninstall clean
