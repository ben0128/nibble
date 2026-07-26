SOURCES := $(wildcard Sources/*.swift)
PREFIX ?= /usr/local
APP := Nibble.app
APP_DEST ?= /Applications
# 有這個自簽身分就用它簽名：designated requirement 跨重建穩定，
# macOS 的「輔助使用」授權才不會每次改版就失效（ad-hoc 簽章的 cdhash 會變）。
# 建立方式見 README 的 Development 段落。
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
		     echo "signed ad-hoc (Accessibility grants will reset on each rebuild)"; }
	@echo "bundle: $$(du -sh $(APP) | cut -f1)"

# 裝到 /Applications：路徑穩定，權限授權給這一份，repo 裡怎麼重建都不影響
install-app: app
	rm -rf "$(APP_DEST)/$(APP)"
	ditto $(APP) "$(APP_DEST)/$(APP)"   # ditto 保留簽名封印，cp -R 會弄壞
	@xattr -cr "$(APP_DEST)/$(APP)"     # 複製過程又會沾上 FinderInfo，清掉才過得了 --strict
	@codesign --verify --deep --strict "$(APP_DEST)/$(APP)" && echo "installed & verified: $(APP_DEST)/$(APP)"

install: nibble
	install -d $(PREFIX)/bin
	install -m 755 nibble $(PREFIX)/bin/nibble
	@echo "installed: $(PREFIX)/bin/nibble"

uninstall:
	rm -f $(PREFIX)/bin/nibble
	rm -rf "$(APP_DEST)/$(APP)"

clean:
	rm -f nibble
	rm -rf $(APP)

.PHONY: app install-app install uninstall clean
