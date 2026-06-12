# Host unit tests for WalkLabTransport (O1) + GamepadPilot (H1+H2) pure logic.
# 로봇 toolchain·Robot:: 프레임워크 불요 — pure 로직만 빌드/실행.
# C++03 으로 빌드해 로봇 g++ 호환 가정을 호스트에서도 강제한다.
#
#   make            # build + run (양쪽)
#   make build      # build only
#   make clean

CXX      ?= c++
CXXFLAGS ?= -std=c++03 -Wall -Wextra -O0 -g -pthread
SRC       = ../WalkLabTransport.cpp test_transport.cpp
BIN       = test_transport
GP_SRC    = ../WalkLabTransport.cpp ../GamepadPilot.cpp test_gamepad.cpp
GP_BIN    = test_gamepad

.PHONY: all build run clean
all: run

build: $(BIN) $(GP_BIN)

$(BIN): $(SRC) ../WalkLabTransport.h
	$(CXX) $(CXXFLAGS) -o $(BIN) $(SRC)

$(GP_BIN): $(GP_SRC) ../WalkLabTransport.h ../GamepadPilot.h
	$(CXX) $(CXXFLAGS) -o $(GP_BIN) $(GP_SRC)

run: $(BIN) $(GP_BIN)
	./$(BIN)
	./$(GP_BIN)

clean:
	rm -f $(BIN) $(GP_BIN)
