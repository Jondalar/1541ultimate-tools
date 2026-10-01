import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from u64ii_menu import Screen  # noqa: E402


class ScreenTest(unittest.TestCase):
    def test_cursor_position_and_clear(self):
        s = Screen()
        s.feed(b"junk\x1bc\x1b[0;37;1m\x1b[2;5Hhello\x1b[1;1Hx")
        self.assertEqual(s.text().split("\n"), ["x", "    hello"])

    def test_line_drawing_and_charset_switch(self):
        s = Screen()
        s.feed(b"\x1b(0qq\x1b(Bq")
        self.assertEqual(s.text(), "--q")

    def test_telnet_negotiation_and_split_escape(self):
        s = Screen()
        s.feed(b"\xff\xfe\x22\xff\xfb\x01\x1b[3")
        s.feed(b";4Hz")
        self.assertEqual(s.text().split("\n")[2], "   z")

    def test_erase_to_end_of_line(self):
        s = Screen()
        s.feed(b"abcdef\x1b[1;3H\x1b[K")
        self.assertEqual(s.text(), "ab")


if __name__ == "__main__":
    unittest.main()
