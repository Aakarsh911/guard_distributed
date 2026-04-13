#include <iostream>
#include <sstream>
#include <thread>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

#include "../common/json.hpp"
#include "../common/net.h"
#include "../common/rate_limiter.h"

using json = nlohmann::json;

static void handle_conn(int fd, guard::RateLimiter& limiter) {
    try {
        std::string raw = guard::recv_msg(fd);
        auto msg = json::parse(raw);

        std::string type = msg.value("type", "");

        if (type == "rate_check") {
            std::string user_id = msg.value("user_id", "unknown");
            std::string req_id  = msg.value("req_id",  "unknown");
            auto result = limiter.check(user_id);

            json resp;
            resp["type"]             = "rate_check_resp";
            resp["allowed"]          = result.allowed;
            resp["tokens_remaining"] = result.tokens_remaining;
            guard::send_msg(fd, resp.dump());

            std::ostringstream oss;
            oss << "[coord] req_id=" << req_id
                << " user=" << user_id
                << (result.allowed ? " ALLOWED" : " DENIED")
                << " tokens=" << static_cast<int>(result.tokens_remaining)
                << "\n";
            auto s = oss.str();
            ::write(STDERR_FILENO, s.data(), s.size());
        } else {
            std::cerr << "[coord] unknown message type: " << type << "\n";
        }
    } catch (const std::exception& e) {
        std::cerr << "[coord] error: " << e.what() << "\n";
    }
    ::close(fd);
}

int main(int argc, char* argv[]) {
    int    port       = (argc > 1) ? std::atoi(argv[1]) : 9200;
    double rl_cap     = (argc > 2) ? std::atof(argv[2]) : 10;
    double rl_refill  = (argc > 3) ? std::atof(argv[3]) : 5;

    std::signal(SIGPIPE, SIG_IGN);

    guard::RateLimiter limiter(rl_cap, rl_refill);

    int server_fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        std::cerr << "[coord] socket(): " << strerror(errno) << "\n";
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
        std::cerr << "[coord] bind(): " << strerror(errno) << "\n";
        ::close(server_fd);
        return 1;
    }

    if (::listen(server_fd, 128) < 0) {
        std::cerr << "[coord] listen(): " << strerror(errno) << "\n";
        ::close(server_fd);
        return 1;
    }

    std::cerr << "[coord] listening on port " << port
              << "  capacity=" << rl_cap
              << "  refill=" << rl_refill << "/s\n";

    while (true) {
        int client_fd = ::accept(server_fd, nullptr, nullptr);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            std::cerr << "[coord] accept(): " << strerror(errno) << "\n";
            continue;
        }
        std::thread(handle_conn, client_fd, std::ref(limiter)).detach();
    }
}
