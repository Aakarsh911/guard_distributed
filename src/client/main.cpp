#include <iostream>
#include <thread>
#include <vector>
#include <chrono>
#include <atomic>
#include <algorithm>
#include <mutex>
#include <cstdlib>
#include <cstring>

#include "../common/json.hpp"
#include "../common/net.h"

using json = nlohmann::json;

static std::atomic<int> g_ok{0};
static std::atomic<int> g_rate_limited{0};
static std::atomic<int> g_err{0};
static std::atomic<int> g_seq{0};

static std::mutex               g_lat_mu;
static std::vector<int64_t>     g_latencies;

static void worker(const std::string& host, int port,
                   const std::string& user_id, int n_reqs) {
    for (int i = 0; i < n_reqs; ++i) {
        auto t0 = std::chrono::steady_clock::now();

        int fd = guard::connect_to(host, port);
        if (fd < 0) { ++g_err; continue; }

        int seq = g_seq.fetch_add(1);
        json req;
        req["type"]    = "request";
        req["user_id"] = user_id;
        req["req_id"]  = user_id + "-" + std::to_string(seq);
        req["payload"] = "hello";

        std::string status;
        try {
            guard::send_msg(fd, req.dump());
            std::string raw = guard::recv_msg(fd);
            auto resp = json::parse(raw);
            status = resp.value("status", "");
        } catch (const std::exception& e) {
            std::cerr << "[client] req " << seq << ": " << e.what() << "\n";
        }

        ::close(fd);

        if (status == "ok")                ++g_ok;
        else if (status == "rate_limited") ++g_rate_limited;
        else                               ++g_err;

        auto t1 = std::chrono::steady_clock::now();
        int64_t us = std::chrono::duration_cast<
                         std::chrono::microseconds>(t1 - t0).count();
        {
            std::lock_guard<std::mutex> lk(g_lat_mu);
            g_latencies.push_back(us);
        }
    }
}

int main(int argc, char* argv[]) {
    std::string host = (argc > 1) ? argv[1] : "127.0.0.1";
    int port         = (argc > 2) ? std::atoi(argv[2]) : 8080;
    int n_requests   = (argc > 3) ? std::atoi(argv[3]) : 100;
    int n_threads    = (argc > 4) ? std::atoi(argv[4]) : 4;
    std::string user = (argc > 5) ? argv[5] : "user1";

    std::cerr << "[client] target=" << host << ":" << port
              << "  requests=" << n_requests
              << "  threads=" << n_threads
              << "  user=" << user << "\n";

    int base  = n_requests / n_threads;
    int extra = n_requests % n_threads;

    std::vector<std::thread> threads;
    threads.reserve(n_threads);
    for (int t = 0; t < n_threads; ++t) {
        int count = base + (t < extra ? 1 : 0);
        threads.emplace_back(worker, host, port, user, count);
    }
    for (auto& t : threads) t.join();

    std::sort(g_latencies.begin(), g_latencies.end());

    int64_t p50 = 0, p99 = 0;
    if (!g_latencies.empty()) {
        size_t sz = g_latencies.size();
        p50 = g_latencies[sz * 50 / 100];
        p99 = g_latencies[std::min(sz * 99 / 100, sz - 1)];
    }

    std::cout << "=== GUARD Client Summary ===\n"
              << "  total:        " << n_requests << "\n"
              << "  ok:           " << g_ok.load() << "\n"
              << "  rate_limited: " << g_rate_limited.load() << "\n"
              << "  errors:       " << g_err.load() << "\n"
              << "  p50 (us):     " << p50 << "\n"
              << "  p99 (us):     " << p99 << "\n";

    return (g_err.load() > 0) ? 1 : 0;
}
