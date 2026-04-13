#pragma once

#include <chrono>
#include <mutex>
#include <string>
#include <unordered_map>

namespace guard {

class TokenBucket {
public:
    TokenBucket(double capacity, double refill_per_sec)
        : tokens_(capacity),
          capacity_(capacity),
          refill_per_sec_(refill_per_sec),
          last_refill_(std::chrono::steady_clock::now()) {}

    bool try_consume() {
        refill();
        if (tokens_ >= 1.0) {
            tokens_ -= 1.0;
            return true;
        }
        return false;
    }

    double tokens() const { return tokens_; }

private:
    void refill() {
        auto now     = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - last_refill_).count();
        tokens_      = std::min(capacity_, tokens_ + elapsed * refill_per_sec_);
        last_refill_ = now;
    }

    double tokens_;
    double capacity_;
    double refill_per_sec_;
    std::chrono::steady_clock::time_point last_refill_;
};

// Thread-safe per-user rate limiter.  One TokenBucket per user_id,
// created on first sight with the configured capacity and refill rate.
struct RateResult {
    bool   allowed;
    double tokens_remaining;
};

class RateLimiter {
public:
    RateLimiter(double capacity, double refill_per_sec)
        : capacity_(capacity), refill_per_sec_(refill_per_sec) {}

    RateResult check(const std::string& user_id) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = buckets_.find(user_id);
        if (it == buckets_.end()) {
            it = buckets_.emplace(
                     user_id,
                     TokenBucket(capacity_, refill_per_sec_)).first;
        }
        bool ok = it->second.try_consume();
        return {ok, it->second.tokens()};
    }

    bool allow(const std::string& user_id) {
        return check(user_id).allowed;
    }

private:
    std::mutex mu_;
    std::unordered_map<std::string, TokenBucket> buckets_;
    double capacity_;
    double refill_per_sec_;
};

}  // namespace guard
