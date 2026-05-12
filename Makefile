# DarwinForge top-level Makefile — 한 명령 빌드/실행 단축.

ROOT      := $(shell pwd)
CARGO_DIR := app/core
SWIFT_PKG := app/ui/DarwinForge

.PHONY: help all mac mac-universal app run test clean lint headers vendor doctor

help:
	@echo "DarwinForge — Make targets"
	@echo ""
	@echo "  make doctor       사전 도구 점검 (git/python3/node/cargo/rustc/swift)"
	@echo "  make mac          호스트 아키 .a + 헤더 빌드 + Vendor/ 채움"
	@echo "  make mac-universal  Apple Silicon + Intel universal binary"
	@echo "  make app          mac + swift build (앱 컴파일)"
	@echo "  make run          mac + swift run DarwinForgeApp (앱 실행)"
	@echo "  make test         cargo test --workspace"
	@echo "  make lint         cargo fmt --check + cargo clippy -D warnings"
	@echo "  make headers      cbindgen으로 forge_core.h.in 갱신"
	@echo "  make clean        target/, .build/, Vendor/ 산출물 정리"

doctor:
	@bash scripts/bootstrap-tools.sh

mac:
	@bash scripts/build-mac.sh

mac-universal:
	@bash scripts/build-mac.sh -u

app:
	@bash scripts/build-mac.sh --swift

run:
	@bash scripts/build-mac.sh --run

test:
	@cargo test --manifest-path $(CARGO_DIR)/Cargo.toml --workspace

lint:
	@cd $(CARGO_DIR) && cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings

headers:
	@cargo build --manifest-path $(CARGO_DIR)/Cargo.toml -p forge-ffi 2>&1 | tail -3
	@find $(CARGO_DIR)/target -name forge_core.h -path '*/build/forge-ffi-*/out/*' \
		| head -1 \
		| xargs -I{} cp {} $(CARGO_DIR)/forge-ffi/forge_core.h.in
	@echo "✓ $(CARGO_DIR)/forge-ffi/forge_core.h.in 갱신"

clean:
	@rm -rf $(CARGO_DIR)/target
	@rm -rf $(SWIFT_PKG)/.build
	@rm -f  $(SWIFT_PKG)/Vendor/CForgeCore/include/forge_core.h
	@rm -f  $(SWIFT_PKG)/Vendor/CForgeCore/include/module.modulemap
	@rm -f  $(SWIFT_PKG)/Vendor/CForgeCore/lib/libforge_core.a
	@echo "✓ clean"
