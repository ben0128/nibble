SOURCES := $(wildcard Sources/*.swift)

nibble: $(SOURCES)
	swiftc -O -swift-version 5 $(SOURCES) -o nibble
	@echo "binary: $$(du -h nibble | cut -f1)"

clean:
	rm -f nibble

.PHONY: clean
