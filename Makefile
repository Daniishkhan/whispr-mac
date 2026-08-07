CONFIG    ?= debug
APP_NAME   = Whispr
BUNDLE     = $(APP_NAME).app
BINARY     = .build/$(CONFIG)/$(APP_NAME)
CERT_NAME  = Whispr Dev
BUNDLE_ID  = com.whispr.app

.PHONY: build app run clean cert

# If the Xcode license hasn't been accepted yet (fresh Xcode install),
# build with the Command Line Tools toolchain, which doesn't check it.
ifeq ($(wildcard /Library/Preferences/com.apple.dt.Xcode.plist),)
    ifneq ($(findstring Xcode.app,$(shell xcode-select -p)),)
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    endif
endif

build:
	swift build -c $(CONFIG)

app: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@if security find-identity -v -p codesigning | grep -q "$(CERT_NAME)"; then \
		echo ">> Signing with '$(CERT_NAME)'"; \
		codesign --force --sign "$(CERT_NAME)" --identifier $(BUNDLE_ID) $(BUNDLE); \
	else \
		echo ">> No '$(CERT_NAME)' identity found - ad-hoc signing."; \
		echo ">> Run 'make cert' once to keep Keychain/Accessibility grants across rebuilds."; \
		codesign --force --sign - $(BUNDLE); \
	fi
	@echo ">> Built $(BUNDLE) ($(CONFIG))"

run: app
	@-pkill -x $(APP_NAME) 2>/dev/null || true
	@open $(BUNDLE)

cert:
	@scripts/make-cert.sh

clean:
	rm -rf .build $(BUNDLE)
