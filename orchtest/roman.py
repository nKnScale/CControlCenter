"""Convert integers to uppercase Roman numerals."""

_NUMERALS = (
    (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
    (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
    (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
)


def to_roman(n):
    """Return the Roman numeral for n, which must be an integer from 1 to 3999.

    Booleans are not accepted as integers. Every rejection raises ValueError.
    """
    if isinstance(n, bool) or not isinstance(n, int):
        raise ValueError("n must be an integer; booleans are not accepted")
    if not 1 <= n <= 3999:
        raise ValueError("n must be between 1 and 3999")
    parts = []
    for value, numeral in _NUMERALS:
        count, n = divmod(n, value)
        parts.append(numeral * count)
    return "".join(parts)
