#include <iostream>
#include <sstream>
#include <memory>
#include <thread>
#include <mutex>
#include <vector>
#include <unordered_map>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

#include "../common/json.hpp"
#include "../common/net.h"
#include "../common/rate_limiter.h"
#include "../common/redis_rate_limiter.h"

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;

// ── worker + task tracking ──────────────────────────────────────────

struct WorkerInfo {
    std::string host;
    int         port;
    Clock::time_point last_hb;
};

struct TaskInfo {
    std::string task_id;
    std::string user_id;
    std::string payload;
    std::string worker_id;
    Clock::time_point deadline;
    bool done       = false;
    bool reassigned = false;
};

static std::mutex g_mu;
static std::unordered_map<std::string, WorkerInfo> g_workers;
static std::unordered_map<std::string, TaskInfo>   g_tasks;

static void coord_log(const std::string& s) {
    ::write(STDERR_FILENO, s.data(), s.size());
}

// ── handle one incoming connection ──────────────────────────────────

static void handle_conn(int fd, guard::IRateLimiter& limiter) {
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
            coord_log(oss.str());

        } else if (type == "worker_register") {
            std::string wid  = msg.value("worker_id", "");
            std::string host = msg.value("host", "127.0.0.1");
            int wport        = msg.value("port", 0);

            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_workers[wid] = {host, wport, Clock::now()};
            }

            json resp;
            resp["type"]   = "worker_register_resp";
            resp["status"] = "ok";
            guard::send_msg(fd, resp.dump());

            std::ostringstream oss;
            oss << "[coord] REGISTER worker=" << wid
                << " addr=" << host << ":" << wport << "\n";
            coord_log(oss.str());

        } else if (type == "heartbeat") {
            std::string wid = msg.value("worker_id", "");
            {
                std::lock_guard<std::mutex> lk(g_mu);
                auto it = g_workers.find(wid);
                if (it != g_workers.end())
                    it->second.last_hb = Clock::now();
            }
            json resp;
            resp["type"]   = "heartbeat_resp";
            resp["status"] = "ok";
            guard::send_msg(fd, resp.dump());

        } else if (type == "task_start") {
            std::string task_id   = msg.value("task_id", "");
            std::string wid       = msg.value("worker_id", "");
            std::string user_id   = msg.value("user_id", "");
            std::string payload   = msg.value("payload", "");
            int         deadline_ms = msg.value("deadline_ms", 10000);

            {
                std::lock_guard<std::mutex> lk(g_mu);
                g_tasks[task_id] = {
                    task_id, user_id, payload, wid,
                    Clock::now() + std::chrono::milliseconds(deadline_ms),
                    false, false
                };
            }

            json resp;
            resp["type"]   = "task_start_resp";
            resp["status"] = "ok";
            guard::send_msg(fd, resp.dump());

            std::ostringstream oss;
            oss << "[coord] TASK_START task=" << task_id
                << " worker=" << wid
                << " deadline=" << deadline_ms << "ms\n";
            coord_log(oss.str());

        } else if (type == "task_done") {
            std::string task_id = msg.value("task_id", "");
            std::string wid     = msg.value("worker_id", "");

            {
                std::lock_guard<std::mutex> lk(g_mu);
                auto it = g_tasks.find(task_id);
                if (it != g_tasks.end())
                    it->second.done = true;
            }

            json resp;
            resp["type"]   = "task_done_resp";
            resp["status"] = "ok";
            guard::send_msg(fd, resp.dump());

            std::ostringstream oss;
            oss << "[coord] TASK_DONE task=" << task_id
                << " worker=" << wid << "\n";
            coord_log(oss.str());

        } else {
            std::ostringstream oss;
            oss << "[coord] unknown message type: " << type << "\n";
            coord_log(oss.str());
        }
    } catch (const std::exception& e) {
        std::ostringstream oss;
        oss << "[coord] error: " << e.what() << "\n";
        coord_log(oss.str());
    }
    ::close(fd);
}

// ── deadline scanner / reassignment thread ──────────────────────────

static void scanner_loop(int hb_timeout_ms, int scan_interval_ms) {
    while (true) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(scan_interval_ms));

        auto now = Clock::now();
        std::vector<TaskInfo> expired;
        std::vector<std::pair<std::string, WorkerInfo>> live;

        {
            std::lock_guard<std::mutex> lk(g_mu);
            for (auto& [tid, task] : g_tasks) {
                if (task.done || task.reassigned) continue;
                if (now < task.deadline) continue;
                auto wit = g_workers.find(task.worker_id);
                if (wit == g_workers.end()) {
                    expired.push_back(task);
                    continue;
                }
                auto since_hb = std::chrono::duration_cast<
                    std::chrono::milliseconds>(now - wit->second.last_hb).count();
                if (since_hb > hb_timeout_ms)
                    expired.push_back(task);
            }
            for (auto& [wid, info] : g_workers) {
                auto since_hb = std::chrono::duration_cast<
                    std::chrono::milliseconds>(now - info.last_hb).count();
                if (since_hb <= hb_timeout_ms)
                    live.push_back({wid, info});
            }
        }

        for (auto& task : expired) {
            bool reassigned = false;
            for (auto& [wid, info] : live) {
                if (wid == task.worker_id) continue;

                int fd = guard::connect_to(info.host, info.port);
                if (fd < 0) continue;

                json msg;
                msg["type"]    = "reassign";
                msg["task_id"] = task.task_id;
                msg["user_id"] = task.user_id;
                msg["payload"] = task.payload;

                try {
                    guard::send_msg(fd, msg.dump());
                    std::string resp_raw = guard::recv_msg(fd);
                    ::close(fd);
                    auto resp = json::parse(resp_raw);
                    if (resp.value("status", "") == "ok") {
                        reassigned = true;
                        std::lock_guard<std::mutex> lk(g_mu);
                        auto it = g_tasks.find(task.task_id);
                        if (it != g_tasks.end()) {
                            it->second.done       = true;
                            it->second.reassigned  = true;
                            it->second.worker_id   = wid;
                        }
                        std::ostringstream oss;
                        oss << "[coord] REASSIGNED task=" << task.task_id
                            << " from=" << task.worker_id
                            << " to=" << wid << "\n";
                        coord_log(oss.str());
                        break;
                    }
                } catch (...) {
                    ::close(fd);
                }
            }
            if (!reassigned) {
                std::ostringstream oss;
                oss << "[coord] REASSIGN_FAILED task=" << task.task_id
                    << " (no live workers available)\n";
                coord_log(oss.str());
            }
        }
    }
}

// ── main ────────────────────────────────────────────────────────────

int main(int argc, char* argv[]) {
    int    port       = (argc > 1) ? std::atoi(argv[1]) : 9200;
    double rl_cap     = (argc > 2) ? std::atof(argv[2]) : 10;
    double rl_refill  = (argc > 3) ? std::atof(argv[3]) : 5;
    std::string redis_addr = (argc > 4) ? argv[4] : "";

    int hb_timeout_ms    = 2000;
    int scan_interval_ms = 500;

    std::signal(SIGPIPE, SIG_IGN);

    std::unique_ptr<guard::IRateLimiter> limiter;
    if (!redis_addr.empty()) {
        auto hp = guard::parse_host_port(redis_addr);
        limiter = std::make_unique<guard::RedisRateLimiter>(
            hp.host, hp.port, rl_cap, rl_refill);
        std::cerr << "[coord] using Redis backend at " << redis_addr << "\n";
    } else {
        limiter = std::make_unique<guard::RateLimiter>(rl_cap, rl_refill);
        std::cerr << "[coord] using in-memory backend\n";
    }

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
              << "  refill=" << rl_refill << "/s"
              << "  hb_timeout=" << hb_timeout_ms << "ms"
              << "  scan_interval=" << scan_interval_ms << "ms\n";

    std::thread(scanner_loop, hb_timeout_ms, scan_interval_ms).detach();

    while (true) {
        int client_fd = ::accept(server_fd, nullptr, nullptr);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            std::cerr << "[coord] accept(): " << strerror(errno) << "\n";
            continue;
        }
        std::thread(handle_conn, client_fd, std::ref(*limiter)).detach();
    }
}
