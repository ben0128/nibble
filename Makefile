SOURCES := $(wildcard Sources/*.swift)

benmouse: $(SOURCES)
	swiftc -O -swift-version 5 $(SOURCES) -o benmouse
	@echo "binary: $$(du -h benmouse | cut -f1)"

clean:
	rm -f benmouse

.PHONY: clean
