# Host unit tests for WalkLabTransport (O1 pure logic).
# 로봇 toolchain·Robot:: 프레임워크 불요 — pure transport 로직만 빌드/실행.
# C++03 으로 빌드해 로봇 g++ 호환 가정을 호스트에서도 강제한다.
#
#   make            # build + run
#   make build      # build only
#   make clean

CXX      ?= c++
CXXFLAGS ?= -std=c++03 -Wall -Wextra -O0 -g -pthread
SRC       = ../WalkLabTransport.cpp test_transport.cpp
BIN       = test_transport

.PHONY: all build run clean
all: run

build: $(BIN)

$(BIN): $(SRC) ../WalkLabTransport.h
	$(CXX) $(CXXFLAGS) -o $(BIN) $(SRC)

run: $(BIN)
	./$(BIN)

clean:
	rm -f $(BIN)
