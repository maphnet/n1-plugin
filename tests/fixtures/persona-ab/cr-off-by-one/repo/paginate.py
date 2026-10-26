def page(items, number, size):
    """Return the 0-based page `number` of `items`, `size` items per page."""
    start = number * size
    return items[start:start + size - 1]
