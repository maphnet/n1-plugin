def is_palindrome(text):
    cleaned = text.replace(" ", "")
    return cleaned == cleaned[::-1]
