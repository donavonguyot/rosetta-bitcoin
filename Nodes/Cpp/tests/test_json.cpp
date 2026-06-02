#include "test_support.hpp"

#include "cpbitnode/util/json.hpp"

void registerJsonTests();

namespace {

using cpbitnode::util::escapeJson;
using cpbitnode::util::jsonArray;
using cpbitnode::util::jsonObject;
using cpbitnode::util::jsonString;

void testEscapeJsonControlAndQuotes() {
    EXPECT_EQ(escapeJson("plain"), "plain");
    EXPECT_EQ(escapeJson("\"\\"), "\\\"\\\\");
    EXPECT_EQ(escapeJson("\b\f\n\r\t"), "\\b\\f\\n\\r\\t");
    EXPECT_EQ(escapeJson(std::string("\x01", 1)), "\\u0001");
    EXPECT_EQ(escapeJson(std::string("\x1f", 1)), "\\u001f");
}

void testJsonStringWrapsEscapedContent() {
    EXPECT_EQ(jsonString("a\"b"), "\"a\\\"b\"");
}

void testJsonObjectCommaSeparation() {
    const std::map<std::string, std::string> fields{{"a", "1"}, {"b", "2"}};
    EXPECT_EQ(jsonObject(fields), "{\"a\":1,\"b\":2}");
    EXPECT_EQ(jsonObject({}), "{}");
}

void testJsonArrayCommaSeparation() {
    EXPECT_EQ(jsonArray({"1", "2"}), "[1,2]");
    EXPECT_EQ(jsonArray({}), "[]");
}

void testEscapeJsonPrintableAsciiPassthrough() {
    EXPECT_EQ(escapeJson("Hello, world!"), "Hello, world!");
}

}  // namespace

void registerJsonTests() {
    RUN_TEST(testEscapeJsonControlAndQuotes);
    RUN_TEST(testJsonStringWrapsEscapedContent);
    RUN_TEST(testJsonObjectCommaSeparation);
    RUN_TEST(testJsonArrayCommaSeparation);
    RUN_TEST(testEscapeJsonPrintableAsciiPassthrough);
}
