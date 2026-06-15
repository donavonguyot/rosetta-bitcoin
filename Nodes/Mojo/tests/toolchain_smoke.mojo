from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _increment(value: Int) -> Int:
    return value + 1


def _is_even(value: Int) -> Bool:
    return value % 2 == 0


def test_integer_arithmetic() raises:
    assert_equal(_increment(41), 42)
    assert_equal(_increment(-1), 0)


def test_boolean_assertions() raises:
    assert_true(_is_even(64))
    assert_false(_is_even(65))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
