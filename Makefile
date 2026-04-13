CXX      := g++
CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -pthread
BUILDDIR := build

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

$(BUILDDIR)/guard_coord: src/coord/main.cpp src/common/net.h src/common/rate_limiter.h src/common/json.hpp
	@mkdir -p $(BUILDDIR)
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -rf $(BUILDDIR)
