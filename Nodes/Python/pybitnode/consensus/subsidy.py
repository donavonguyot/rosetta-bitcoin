from __future__ import annotations

from pybitnode.consensus.constants import COIN, SUBSIDY_HALVING_INTERVAL


def block_subsidy(height: int) -> int:
    if height < 0:
        return 0
    halvings = height // SUBSIDY_HALVING_INTERVAL
    if halvings >= 64:
        return 0
    return (50 * COIN) >> halvings
