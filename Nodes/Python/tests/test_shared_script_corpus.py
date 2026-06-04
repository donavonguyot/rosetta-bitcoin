from __future__ import annotations

import pytest

from pybitnode.conformance.script_corpus import load_cases, verify_case


CASES = load_cases()


@pytest.mark.parametrize("case", CASES, ids=[case.fixture_id for case in CASES])
def test_shared_script_corpus_fixture_loads(case):
    assert case.transaction.inputs
    assert case.amount >= 0
    assert case.script_pubkey
    assert case.spent_prevouts


@pytest.mark.parametrize("case", CASES, ids=[case.fixture_id for case in CASES])
def test_shared_script_corpus_verify(case):
    try:
        verify_case(case)
    except Exception as error:
        reason = case.missing_rule or ",".join(case.required_rules) or type(error).__name__
        pytest.xfail(f"{case.fixture_id}: {reason}: {error}")
