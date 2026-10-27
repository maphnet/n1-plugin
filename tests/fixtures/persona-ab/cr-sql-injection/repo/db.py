import sqlite3


def find_user(conn, name):
    cur = conn.cursor()
    cur.execute("SELECT id, name FROM users WHERE name = '%s'" % name)
    return cur.fetchone()
