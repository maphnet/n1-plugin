def is_palindrome(text):
    cleaned = text.lower()
    return cleaned == cleaned[::-1]
