"""Limit a number to a closed range."""

import math


def clamp(x, lo, hi):
    """Return x limited to the closed range [lo, hi].

    Raises ValueError when lo is greater than hi, or when any argument is NaN.
    """
    for name, value in (("x", x), ("lo", lo), ("hi", hi)):
        if isinstance(value, float) and math.isnan(value):
            raise ValueError(f"{name} must not be NaN")
    if lo > hi:
        raise ValueError("lo must not be greater than hi")
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x
