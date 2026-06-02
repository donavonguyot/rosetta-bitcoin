#pragma once

#include <cstdlib>
#include <iostream>
#include <string>

inline int g_failures = 0;

#define EXPECT_TRUE(expr) \
    do { \
        if (!(expr)) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

#define EXPECT_EQ(a, b) \
    do { \
        const auto _a = (a); \
        const auto _b = (b); \
        if (_a != _b) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected " << _b << " got " << _a << "\n"; \
            ++g_failures; \
        } \
    } while (0)

#define EXPECT_BYTES_EQ(a, b) \
    do { \
        const auto _a = (a); \
        const auto _b = (b); \
        if (_a != _b) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " byte vectors differ (sizes " << _a.size() \
                      << " vs " << _b.size() << ")\n"; \
            ++g_failures; \
        } \
    } while (0)

#define RUN_TEST(fn) \
    do { \
        std::cerr << "RUN " #fn "\n"; \
        fn(); \
    } while (0)
