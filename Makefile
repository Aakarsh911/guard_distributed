CXX      := g++
CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -pthread
BUILDDIR := build

HIREDIS_CFLAGS := $(shell pkg-config --cflags hiredis 2>/dev/null || echo "-I/opt/homebrew/include")
HIREDIS_LIBS   := $(shell pkg-config --libs   hiredis 2>/dev/null || echo "-L/opt/homebrew/lib -lhiredis")

.PHONY: all clean

all: $(BUILDDIR)/guard_server $(BUILDDIR)/guard_client $(BUILDDIR)/guard_lb $(BUILDDIR)/guard_coord

$(BUILDDIR)/guard_server: src/server/main.cpp src/common/net.h src/common/json.hpp
	@mkdir -p $(BUILDDIR)
	$(CXX) $(CXXFLAGS) -o $@ $<

$(BUILDDIR)/guard_client: src/client/main.cpp src/common/net.h src/common/json.hpp
	@mkdir -p $(BUILDDIR)
	$(CXX) $(CXXFLAGS) -o $@ $<

$(BUILDDIR)/guard_lb: src/lb/main.cpp src/common/net.h src/common/json.hpp
	@mkdir -p $(BUILDDIR)
	$(CXX) $(CXXFLAGS) -o $@ $<

$(BUILDDIR)/guard_coord: src/coord/main.cpp src/common/net.h src/common/rate_limiter.h src/common/redis_rate_limiter.h src/common/json.hpp
	@mkdir -p $(BUILDDIR)
	$(CXX) $(CXXFLAGS) $(HIREDIS_CFLAGS) -o $@ $< $(HIREDIS_LIBS)

clean:
	rm -rf $(BUILDDIR)
