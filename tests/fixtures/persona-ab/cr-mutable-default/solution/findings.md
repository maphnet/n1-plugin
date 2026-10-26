cart.py:1 - mutable default `cart=[]` is shared across calls, so carts leak items between callers; default to None.
