from std.algorithm.backend.cpu.parallelize import parallelize
from std.collections import List
from std.testing import assert_equal, TestSuite


def test_parallelize_writes_result_slots() raises:
    var results = List[Int]()
    for _ in range(8):
        results.append(-1)

    @parameter
    def fill(index: Int) capturing:
        results[index] = index * 3

    parallelize[fill](8, 2)

    for i in range(8):
        assert_equal(results[i], i * 3)


def test_parallel_first_failure_reduction() raises:
    var ok = List[Bool]()
    var failure_index = List[Int]()
    for _ in range(8):
        ok.append(True)
        failure_index.append(-1)

    @parameter
    def fill(index: Int) capturing:
        if index == 5 or index == 2:
            ok[index] = False
            failure_index[index] = index

    parallelize[fill](8, 2)

    var first = -1
    for i in range(8):
        if not ok[i] and first == -1:
            first = failure_index[i]
    assert_equal(first, 2)


def test_parallel_result_slot_stress() raises:
    var results = List[Int]()
    var ok = List[Bool]()
    for _ in range(128):
        results.append(-1)
        ok.append(True)

    @parameter
    def fill(index: Int) capturing:
        results[index] = (index * 17) + 3
        if index == 91 or index == 37:
            ok[index] = False

    for _ in range(32):
        parallelize[fill](128, 4)

    for i in range(128):
        assert_equal(results[i], (i * 17) + 3)

    var first = -1
    for i in range(128):
        if not ok[i] and first == -1:
            first = i
    assert_equal(first, 37)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
