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
	@# Finder 會在背景把 com.apple.FinderInfo 加回剛建立的 bundle（這個 repo 在桌面上，
	@# Finder 一直盯著），撞上就 codesign 拒簽。所以每次嘗試前重清屬性，失敗就重試。
	@ERR=$$(mktemp); ok=""; \
	for attempt in 1 2 3; do \
		xattr -cr $(APP) 2>/dev/null; \
		if codesign --force --deep --sign "$(SIGN_ID)" $(APP) 2>$$ERR; then \
			echo "signed with: $(SIGN_ID)"; ok=1; break; \
		fi; \
		if codesign --force --deep --sign - $(APP) 2>>$$ERR; then \
			echo "signed ad-hoc"; ok=1; break; \
		fi; \
		sleep 0.3; \
	done; \
	if [ -z "$$ok" ]; then echo "ERROR: codesign failed after 3 attempts:"; cat $$ERR; rm -f $$ERR; exit 1; fi; \
	rm -f $$ERR
	@# 不用 --strict：它會因為 Finder 隨時加回的 FinderInfo 而失敗，但那不影響執行。
	@# 這裡要擋的是「根本沒簽到」——先前 stderr 被吃掉時就出過那種空殼 bundle。
	@codesign --verify --deep $(APP) \
		|| { echo "ERROR: $(APP) failed signature verification — refusing to ship a broken bundle"; exit 1; }
	@echo "bundle: $$(du -sh $(APP) | cut -f1)"

# 裝到 /Applications：路徑穩定，權限授權給這一份，repo 裡怎麼重建都不影響
install-app: app
	@# 等程序真的結束再替換：睡固定秒數只是猜，太短會撞上「檔案使用中」，太長是白等
	@RUNPAT="$(APP)/Contents/MacOS/nibble"; \
	if pgrep -qf "$$RUNPAT"; then \
		echo "quitting running Nibble…"; \
		pkill -f "$$RUNPAT" || true; \
		for i in $$(seq 1 40); do pgrep -qf "$$RUNPAT" || break; sleep 0.1; done; \
		if pgrep -qf "$$RUNPAT"; then \
			echo "still running after 4s — forcing"; \
			pkill -9 -f "$$RUNPAT" || true; \
			for i in $$(seq 1 20); do pgrep -qf "$$RUNPAT" || break; sleep 0.1; done; \
		fi; \
	fi
	rm -rf "$(APP_DEST)/$(APP)"
	ditto $(APP) "$(APP_DEST)/$(APP)"   # ditto 保留簽名封印，cp -R 會弄壞
	@xattr -cr "$(APP_DEST)/$(APP)" 2>/dev/null || true
	@codesign --verify --deep "$(APP_DEST)/$(APP)" && echo "installed & verified: $(APP_DEST)/$(APP)"

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
