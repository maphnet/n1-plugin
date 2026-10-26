def total(prices, tax=0.1):
    """Sum of prices with tax applied, rounded to cents."""
    return round(sum(prices) * (1 + tax), 2)
