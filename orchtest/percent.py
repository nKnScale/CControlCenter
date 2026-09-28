"""Format a ratio as a percentage string."""

import math


def percent(part, whole, digits=1):
    """Return ``part / whole`` as a percentage rounded to ``digits`` places.

    ``percent(1, 8)`` is ``'12.5%'``. Booleans are not accepted as numbers.
    Raises ValueError when ``whole`` is 0, ``digits`` is negative, or an
    argument is a boolean or otherwise not a finite number. ``digits`` must
    be an integer.
    """
    for name, value in (("part", part), ("whole", whole)):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"{name} must be a real number; booleans are not accepted")
        if not math.isfinite(value):
            raise ValueError(f"{name} must be finite")
    if isinstance(digits, bool) or not isinstance(digits, int):
        raise ValueError("digits must be an integer; booleans are not accepted")
    if digits < 0:
        raise ValueError("digits must be non-negative")
    if whole == 0:
        raise ValueError("whole must not be 0")
    return f"{(part / whole) * 100:.{digits}f}%"
