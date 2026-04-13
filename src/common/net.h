#pragma once

#include <cstdint>
#include <string>
#include <stdexcept>
#include <cerrno>
#include <cstring>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>

namespace guard {

inline bool send_all(int fd, const void* buf, size_t len) {
    const char* p = static_cast<const char*>(buf);
    while (len > 0) {
        ssize_t n = ::send(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        p   += static_cast<size_t>(n);
        len -= static_cast<size_t>(n);
    }
    return true;
}

inline bool recv_all(int fd, void* buf, size_t len) {
    char* p = static_cast<char*>(buf);
    while (len > 0) {
        ssize_t n = ::recv(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;   // peer closed
        p   += static_cast<size_t>(n);
        len -= static_cast<size_t>(n);
    }
    return true;
}

// Wire format: [4-byte big-endian length][payload bytes]
inline bool send_msg(int fd, const std::string& msg) {
    uint32_t net_len = htonl(static_cast<uint32_t>(msg.size()));
    if (!send_all(fd, &net_len, sizeof(net_len))) return false;
    return send_all(fd, msg.data(), msg.size());
}

inline std::string recv_msg(int fd) {
    uint32_t net_len;
    if (!recv_all(fd, &net_len, sizeof(net_len)))
        throw std::runtime_error("recv_msg: failed to read length prefix");
    uint32_t len = ntohl(net_len);
    if (len > 16u * 1024 * 1024)
        throw std::runtime_error("recv_msg: message too large (" +
                                 std::to_string(len) + " bytes)");
    std::string buf(len, '\0');
    if (!recv_all(fd, buf.data(), len))
        throw std::runtime_error("recv_msg: failed to read message body");
    return buf;
}

// Returns connected fd or -1.
inline int connect_to(const std::string& host, int port) {
    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    std::string port_s = std::to_string(port);
    int rc = ::getaddrinfo(host.c_str(), port_s.c_str(), &hints, &res);
    if (rc != 0) return -1;

    int fd = ::socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }

    if (::connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        ::close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
    return fd;
}

struct HostPort {
    std::string host;
    int         port;
};

inline HostPort parse_host_port(const std::string& s) {
    auto pos = s.rfind(':');
    if (pos == std::string::npos || pos == 0 || pos == s.size() - 1)
        throw std::runtime_error("bad host:port spec: " + s);
    return {s.substr(0, pos), std::atoi(s.substr(pos + 1).c_str())};
}

}  // namespace guard
