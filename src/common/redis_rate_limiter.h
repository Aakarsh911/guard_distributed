#pragma once

#include <string>
#include <mutex>
#include <cstring>
#include <chrono>
#include <stdexcept>
#include <hiredis/hiredis.h>

#include "rate_limiter.h"

namespace guard {

class RedisRateLimiter : public IRateLimiter {
public:
    RedisRateLimiter(const std::string& host, int port,
                     double capacity, double refill_per_sec)
        : host_(host), port_(port),
          capacity_(capacity), refill_per_sec_(refill_per_sec),
          ctx_(nullptr)
    {
        connect();
        load_script();
    }

    ~RedisRateLimiter() override {
        if (ctx_) redisFree(ctx_);
    }

    RedisRateLimiter(const RedisRateLimiter&) = delete;
    RedisRateLimiter& operator=(const RedisRateLimiter&) = delete;

    RateResult check(const std::string& user_id) override {
        std::lock_guard<std::mutex> lk(mu_);

        std::string key = "guard:bucket:" + user_id;
        double now = std::chrono::duration<double>(
            std::chrono::system_clock::now().time_since_epoch()).count();

        for (int attempt = 0; attempt < 2; ++attempt) {
            redisReply* reply = eval(key, now);

            if (!reply) {
                reconnect();
                continue;
            }

            if (reply->type == REDIS_REPLY_ERROR &&
                std::strstr(reply->str, "NOSCRIPT")) {
                freeReplyObject(reply);
                load_script();
                continue;
            }

            if (reply->type == REDIS_REPLY_ERROR) {
                std::string err(reply->str);
                freeReplyObject(reply);
                throw std::runtime_error("Redis EVALSHA: " + err);
            }

            RateResult result{};
            if (reply->type == REDIS_REPLY_ARRAY && reply->elements >= 2) {
                result.allowed =
                    (reply->element[0]->integer != 0);
                result.tokens_remaining =
                    static_cast<double>(reply->element[1]->integer);
            }
            freeReplyObject(reply);
            return result;
        }
        throw std::runtime_error("Redis: failed after retries");
    }

private:
    std::string    host_;
    int            port_;
    double         capacity_;
    double         refill_per_sec_;
    redisContext*  ctx_;
    std::string    script_sha_;
    std::mutex     mu_;

    static constexpr const char* LUA_SCRIPT = R"(
local key         = KEYS[1]
local capacity    = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now         = tonumber(ARGV[3])

local data        = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens      = tonumber(data[1])
local last_refill = tonumber(data[2])

if tokens == nil then
    tokens      = capacity
    last_refill = now
end

local elapsed = now - last_refill
tokens = math.min(capacity, tokens + elapsed * refill_rate)

local allowed = 0
if tokens >= 1 then
    tokens  = tokens - 1
    allowed = 1
end

redis.call('HMSET', key, 'tokens', tostring(tokens), 'last_refill', tostring(now))
return {allowed, math.floor(tokens)}
)";

    void connect() {
        ctx_ = redisConnect(host_.c_str(), port_);
        if (!ctx_ || ctx_->err) {
            std::string err = ctx_ ? ctx_->errstr : "allocation failed";
            if (ctx_) { redisFree(ctx_); ctx_ = nullptr; }
            throw std::runtime_error("Redis connect(" +
                                     host_ + ":" + std::to_string(port_) +
                                     "): " + err);
        }
    }

    void reconnect() {
        if (ctx_) { redisFree(ctx_); ctx_ = nullptr; }
        connect();
        load_script();
    }

    void load_script() {
        redisReply* reply = static_cast<redisReply*>(
            redisCommand(ctx_, "SCRIPT LOAD %s", LUA_SCRIPT));
        if (!reply || reply->type != REDIS_REPLY_STRING) {
            std::string err = reply ? (reply->str ? reply->str : "bad type")
                                    : "null reply";
            if (reply) freeReplyObject(reply);
            throw std::runtime_error("SCRIPT LOAD failed: " + err);
        }
        script_sha_ = reply->str;
        freeReplyObject(reply);
    }

    redisReply* eval(const std::string& key, double now) {
        return static_cast<redisReply*>(
            redisCommand(ctx_, "EVALSHA %s 1 %s %f %f %f",
                         script_sha_.c_str(), key.c_str(),
                         capacity_, refill_per_sec_, now));
    }
};

}  // namespace guard
