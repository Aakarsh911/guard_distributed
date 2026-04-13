#include <iostream>
#include <thread>
#include <vector>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

#include "../common/json.hpp"
#include "../common/net.h"

using json = nlohmann::json;

static std::vector<guard::HostPort> g_backends;
static std::atomic<uint64_t> g_rr{0};

static guard::HostPort pick_backend() {
    uint64_t idx = g_rr.fetch_add(1) % g_backends.size();
    return g_backends[idx];
}

static void handle_client(int client_fd) {
    try {
        std::string raw = guard::recv_msg(client_fd);

        std::string req_id = "?";
        try {
            auto j = json::parse(raw);
            req_id = j.value("req_id", "?");
        } catch (...) {}

        // Try backends round-robin; on failure rotate to next
        size_t n = g_backends.size();
        for (size_t attempt = 0; attempt < n; ++attempt) {
            auto be = pick_backend();
            int be_fd = guard::connect_to(be.host, be.port);
            if (be_fd < 0) {
                std::cerr << "[lb] backend " << be.host << ":" << be.port
                          << " unreachable (req_id=" << req_id << ")\n";
                continue;
            }

            if (!guard::send_msg(be_fd, raw)) {
                std::cerr << "[lb] send to backend failed (req_id="
                          << req_id << ")\n";
                ::close(be_fd);
                continue;
            }

            std::string resp;
            try {
                resp = guard::recv_msg(be_fd);
            } catch (...) {
                std::cerr << "[lb] recv from backend failed (req_id="
                          << req_id << ")\n";
                ::close(be_fd);
                continue;
            }
            ::close(be_fd);

            guard::send_msg(client_fd, resp);
            std::cerr << "[lb] req_id=" << req_id
                      << " -> " << be.host << ":" << be.port << "\n";
            ::close(client_fd);
            return;
        }

        // All backends failed
        json err;
        err["type"]   = "response";
        err["req_id"] = req_id;
        err["status"] = "error";
        err["body"]   = "all backends unavailable";
        guard::send_msg(client_fd, err.dump());
        std::cerr << "[lb] req_id=" << req_id << " ALL BACKENDS DOWN\n";

    } catch (const std::exception& e) {
        std::cerr << "[lb] error: " << e.what() << "\n";
    }
    ::close(client_fd);
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        std::cerr << "usage: guard_lb <port> <backend:port> [backend:port ...]\n";
        return 1;
    }

    int port = std::atoi(argv[1]);
    for (int i = 2; i < argc; ++i)
        g_backends.push_back(guard::parse_host_port(argv[i]));

    std::signal(SIGPIPE, SIG_IGN);

    int server_fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        std::cerr << "[lb] socket(): " << strerror(errno) << "\n";
        return 1;
    }

    int opt = 1;
    ::setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons(static_cast<uint16_t>(port));

    if (::bind(server_fd, reinterpret_cast<sockaddr*>(&addr),
               sizeof(addr)) < 0) {
        std::cerr << "[lb] bind(): " << strerror(errno) << "\n";
        ::close(server_fd);
        return 1;
    }

    if (::listen(server_fd, 128) < 0) {
        std::cerr << "[lb] listen(): " << strerror(errno) << "\n";
        ::close(server_fd);
        return 1;
    }

    std::cerr << "[lb] listening on port " << port << "  backends:";
    for (const auto& b : g_backends)
        std::cerr << " " << b.host << ":" << b.port;
    std::cerr << "\n";

    while (true) {
        int client_fd = ::accept(server_fd, nullptr, nullptr);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            std::cerr << "[lb] accept(): " << strerror(errno) << "\n";
            continue;
        }
        std::thread(handle_client, client_fd).detach();
    }
}
