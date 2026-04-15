#include <iostream>
#include <sstream>
#include <thread>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <atomic>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

#include "../common/json.hpp"
#include "../common/net.h"

using json = nlohmann::json;

static void log_err(const std::string& s) {
    ::write(STDERR_FILENO, s.data(), s.size());
}

struct CoordInfo {
    std::string host;
    int         port;
};

// ── coordinator helpers ─────────────────────────────────────────────

struct CoordResult {
    int    rc;                // 1=allowed, 0=denied, -1=unreachable
    double tokens_remaining;
};

static CoordResult check_rate_limit(const CoordInfo& coord,
                                    const std::string& user_id,
                                    const std::string& req_id) {
    int fd = guard::connect_to(coord.host, coord.port);
    if (fd < 0) return {-1, 0};

    json msg;
    msg["type"]    = "rate_check";
    msg["user_id"] = user_id;
    msg["req_id"]  = req_id;

    try {
        guard::send_msg(fd, msg.dump());
        std::string raw = guard::recv_msg(fd);
        auto resp = json::parse(raw);
        bool ok     = resp.value("allowed", false);
        double toks = resp.value("tokens_remaining", 0.0);
        ::close(fd);
        return {ok ? 1 : 0, toks};
    } catch (...) {
        ::close(fd);
        return {-1, 0};
    }
}

static void send_coord_fire_and_forget(const CoordInfo& coord,
                                       const json& msg) {
    int fd = guard::connect_to(coord.host, coord.port);
    if (fd < 0) return;
    try {
        guard::send_msg(fd, msg.dump());
        guard::recv_msg(fd);
    } catch (...) {}
    ::close(fd);
}

static void notify_task_start(const CoordInfo& coord,
                              const std::string& task_id,
                              const std::string& worker_id,
                              const std::string& user_id,
                              const std::string& payload,
                              int deadline_ms) {
    json msg;
    msg["type"]        = "task_start";
    msg["task_id"]     = task_id;
    msg["worker_id"]   = worker_id;
    msg["user_id"]     = user_id;
    msg["payload"]     = payload;
    msg["deadline_ms"] = deadline_ms;
    send_coord_fire_and_forget(coord, msg);
}

static void notify_task_done(const CoordInfo& coord,
                             const std::string& task_id,
                             const std::string& worker_id) {
    json msg;
    msg["type"]      = "task_done";
    msg["task_id"]   = task_id;
    msg["worker_id"] = worker_id;
    send_coord_fire_and_forget(coord, msg);
}

// ── heartbeat thread ────────────────────────────────────────────────

static std::atomic<bool> g_running{true};

static void heartbeat_loop(CoordInfo coord, std::string worker_id) {
    while (g_running.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        json msg;
        msg["type"]      = "heartbeat";
        msg["worker_id"] = worker_id;
        send_coord_fire_and_forget(coord, msg);
    }
}

// ── handle one incoming connection ──────────────────────────────────

static void handle_client(int client_fd, int sim_ms,
                          int my_port,
                          const std::string& worker_id,
                          const CoordInfo* coord) {
    try {
        std::string raw = guard::recv_msg(client_fd);
        auto start = std::chrono::steady_clock::now();

        auto req = json::parse(raw);
        std::string msg_type = req.value("type", "request");
        std::string req_id   = req.value("req_id",  "unknown");
        std::string user_id  = req.value("user_id", "unknown");
        std::string payload  = req.value("payload", "");

        // ── reassign from coordinator ───────────────────────────────
        if (msg_type == "reassign") {
            std::string task_id = req.value("task_id", req_id);

            std::ostringstream oss;
            oss << "[worker:" << my_port << "] REASSIGN task=" << task_id
                << " user=" << user_id << "\n";
            log_err(oss.str());

            std::this_thread::sleep_for(std::chrono::milliseconds(sim_ms));

            if (coord)
                notify_task_done(*coord, task_id, worker_id);

            json resp;
            resp["type"]    = "reassign_resp";
            resp["task_id"] = task_id;
            resp["status"]  = "ok";
            guard::send_msg(client_fd, resp.dump());

            oss.str("");
            oss << "[worker:" << my_port << "] REASSIGN_DONE task="
                << task_id << "\n";
            log_err(oss.str());

            ::close(client_fd);
            return;
        }

        // ── normal client request ───────────────────────────────────
        json resp;
        resp["type"]   = "response";
        resp["req_id"] = req_id;

        bool allowed = true;
        double tokens_remaining = -1;
        if (coord) {
            auto cr = check_rate_limit(*coord, user_id, req_id);
            tokens_remaining = cr.tokens_remaining;
            if (cr.rc <= 0) {
                allowed = false;
                resp["status"] = "rate_limited";
                resp["body"]   = (cr.rc < 0) ? "coordinator unreachable"
                                             : "rate limit exceeded";
                std::ostringstream oss;
                oss << "[worker:" << my_port << "] req_id=" << req_id
                    << " user=" << user_id
                    << (cr.rc < 0 ? " COORD_DOWN" : " RATE_LIMITED")
                    << " tokens=" << static_cast<int>(tokens_remaining)
                    << "\n";
                log_err(oss.str());
            }
        }

        if (allowed) {
            std::string task_id = worker_id + "/" + req_id;
            int deadline_ms = sim_ms + 2000;
            if (coord)
                notify_task_start(*coord, task_id, worker_id,
                                  user_id, payload, deadline_ms);

            std::this_thread::sleep_for(std::chrono::milliseconds(sim_ms));

            if (coord)
                notify_task_done(*coord, task_id, worker_id);

            resp["status"] = "ok";
            resp["body"]   = "processed";
        }

        if (!guard::send_msg(client_fd, resp.dump())) {
            std::ostringstream oss;
            oss << "[worker:" << my_port << "] send failed for req_id="
                << req_id << "\n";
            log_err(oss.str());
        }

        auto end = std::chrono::steady_clock::now();
        auto us  = std::chrono::duration_cast<std::chrono::microseconds>(
                       end - start).count();

        if (allowed) {
            std::ostringstream oss;
            oss << "[worker:" << my_port << "] req_id=" << req_id
                << " user=" << user_id << " OK";
            if (tokens_remaining >= 0)
                oss << " tokens=" << static_cast<int>(tokens_remaining);
            oss << " took=" << us << "us\n";
            log_err(oss.str());
        }
    } catch (const std::exception& e) {
        std::ostringstream oss;
        oss << "[worker:" << my_port << "] error: " << e.what() << "\n";
        log_err(oss.str());
    }
    ::close(client_fd);
}

// ── main ────────────────────────────────────────────────────────────

int main(int argc, char* argv[]) {
    int port   = (argc > 1) ? std::atoi(argv[1]) : 8080;
    int sim_ms = (argc > 2) ? std::atoi(argv[2]) : 5;

    std::signal(SIGPIPE, SIG_IGN);

    std::string worker_id = "w-" + std::to_string(port);

    CoordInfo* coord = nullptr;
    if (argc > 3) {
        auto hp = guard::parse_host_port(argv[3]);
        coord = new CoordInfo{hp.host, hp.port};
        std::cerr << "[worker:" << port << "] coordinator: "
                  << hp.host << ":" << hp.port << "\n";

        // register with coordinator
        json reg;
        reg["type"]      = "worker_register";
        reg["worker_id"] = worker_id;
        reg["host"]      = "127.0.0.1";
        reg["port"]      = port;
        send_coord_fire_and_forget(*coord, reg);
        std::cerr << "[worker:" << port << "] registered as " << worker_id << "\n";

        // start heartbeat thread
        std::thread(heartbeat_loop, *coord, worker_id).detach();
    }

    int server_fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        std::cerr << "[worker] socket(): " << strerror(errno) << "\n";
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
        std::cerr << "[worker] bind(): " << strerror(errno) << "\n";
        ::close(server_fd);
        return 1;
    }

    if (::listen(server_fd, 128) < 0) {
        std::cerr << "[worker] listen(): " << strerror(errno) << "\n";
        ::close(server_fd);
        return 1;
    }

    std::cerr << "[worker:" << port << "] listening  sim_ms=" << sim_ms << "\n";

    while (true) {
        int client_fd = ::accept(server_fd, nullptr, nullptr);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            std::cerr << "[worker] accept(): " << strerror(errno) << "\n";
            continue;
        }
        std::thread(handle_client, client_fd, sim_ms, port,
                    worker_id, coord).detach();
    }
}
