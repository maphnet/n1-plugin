def is_palindrome(text):
    """True if text reads the same backwards, ignoring case and spaces."""
    cleaned = text.replace(" ", "").lower()
    return cleaned == cleaned[::-1]
