#!/usr/bin/env python3
"""Host tests for u64ii_jtag.py against a simulated FT232H and FPGA.

The model interprets the MPSSE commands the tool sends, clocks a 7-series TAP
edge by edge, and behind USER4 runs a Python transcription of
fpga/io/jtag/vhdl_source/jtag_client_xilinx.vhd: the select bit, the
register select, the FIFOs with their registered pop and put pulses, and the
memory command decoder. TDO is sampled on the rising edge from the value the
TAP presented after the previous edge.

It proves the tool and the transcription agree with each other. It does not
prove either agrees with the hardware; the first run on a real board does
that, starting with `probe`, whose 0xDEAD1541 check catches an off-by-one in
the scan framing.

    python3 tooling/test_u64ii_jtag.py
"""

import io
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ["U64II_JTAG_LOCK"] = "off"     # never touch the real device lock
import u64ii_jtag as jt  # noqa: E402

# TAP states
TLR, RTI, SEL_DR, CAP_DR, SH_DR, EX1_DR, PA_DR, EX2_DR, UPD_DR, \
    SEL_IR, CAP_IR, SH_IR, EX1_IR, PA_IR, EX2_IR, UPD_IR = range(16)
NEXT = {
    TLR: (RTI, TLR), RTI: (RTI, SEL_DR), SEL_DR: (CAP_DR, SEL_IR),
    CAP_DR: (SH_DR, EX1_DR), SH_DR: (SH_DR, EX1_DR), EX1_DR: (PA_DR, UPD_DR),
    PA_DR: (PA_DR, EX2_DR), EX2_DR: (SH_DR, UPD_DR), UPD_DR: (RTI, SEL_DR),
    SEL_IR: (CAP_IR, TLR), CAP_IR: (SH_IR, EX1_IR), SH_IR: (SH_IR, EX1_IR),
    EX1_IR: (PA_IR, UPD_IR), PA_IR: (PA_IR, EX2_IR), EX2_IR: (SH_IR, UPD_IR),
    UPD_IR: (RTI, SEL_DR),
}


class UserChainModel:
    """jtag_client_xilinx, one rising edge of jtck at a time."""

    def __init__(self, memory):
        self.memory = memory
        self.ir_in = 0
        self.ir_shift = 0
        self.expect_sel = self.isel = self.dsel = 0
        self.bit_count = self.wbit_count = 0
        self.shiftreg_fifo = 0
        self.shiftreg_write = 0
        self.shiftreg_console = 0
        self.shiftreg_debug = 0
        self.write_vector = 0
        self.read_fifo, self.console_fifo, self.write_fifo = [], [], []
        self.read_fifo_get = self.console_fifo_get = self.write_fifo_put = 0
        # avm side
        self.address = 0
        self.write_enabled = self.incrementing = 0
        self.byte_count = 0
        self.write_data = [0, 0, 0, 0]
        self.pending_reads = []
        self.lost_writes = 0

    def tdo(self):
        if self.isel:
            return self.ir_shift & 1
        if self.ir_in == 0:
            return (jt.USER_ID_VALUE >> (self.bit_count & 31)) & 1
        if self.ir_in == 2:
            return self.shiftreg_write & 1
        if self.ir_in == 3:
            return self.shiftreg_debug & 1
        if self.ir_in == 4:
            return self.shiftreg_fifo & 1
        if self.ir_in == 0xA:
            return self.shiftreg_console & 1
        return 0

    def edge(self, sel, capture, shift, update, tdi):
        # Registered pulses from the previous edge act now.
        if self.read_fifo_get and self.read_fifo:
            self.read_fifo.pop(0)
        if self.console_fifo_get and self.console_fifo:
            self.console_fifo.pop(0)
        if self.write_fifo_put:
            word = (0x800 | (self.shiftreg_fifo >> 8) & 0xFF) if self.ir_in == 6 \
                else self.shiftreg_fifo & 0xFFF
            if len(self.write_fifo) < 15:
                self.write_fifo.append(word)
            else:
                self.lost_writes += 1
        self.read_fifo_get = self.console_fifo_get = self.write_fifo_put = 0

        old = dict(isel=self.isel, dsel=self.dsel, expect_sel=self.expect_sel,
                   ir_in=self.ir_in)
        if sel:
            # process 1
            if capture:
                self.ir_shift = self.ir_in
                self.expect_sel = 1
            elif shift:
                self.expect_sel = 0
                if old["expect_sel"]:
                    self.isel, self.dsel = tdi, 1 - tdi
                elif old["isel"]:
                    self.ir_shift = (tdi << 3) | (self.ir_shift >> 1)
            elif update:
                if old["isel"]:
                    self.ir_in = self.ir_shift
                self.isel = self.dsel = 0

        ir = old["ir_in"]
        if shift and old["dsel"]:
            self.shiftreg_write = (tdi << 7) | (self.shiftreg_write >> 1)
            wbc = self.wbit_count
            self.wbit_count = (wbc + 1) & 15
            if ir == 5:
                self.shiftreg_fifo = (tdi << 15) | (self.shiftreg_fifo >> 1)
                self.write_fifo_put = int(wbc == 15)
            elif ir == 6:
                self.shiftreg_fifo = (tdi << 15) | (self.shiftreg_fifo >> 1)
                self.write_fifo_put = int((wbc & 7) == 7)
            bc = self.bit_count
            self.bit_count = (bc + 1) & 31
            if ir == 4:
                if bc & 7 == 7:
                    self.shiftreg_fifo = self.read_fifo[0] if self.read_fifo else 0x5A
                    self.read_fifo_get = 1 - tdi
                else:
                    self.shiftreg_fifo >>= 1
            elif ir == 0xA:
                if bc & 7 == 7:
                    self.shiftreg_console = self.console_fifo[0] if self.console_fifo else 0x5A
                    self.console_fifo_get = 1 - tdi
                else:
                    self.shiftreg_console >>= 1
            self.shiftreg_debug >>= 1
        if sel and capture:
            self.shiftreg_write = self.write_vector
            self.bit_count = self.wbit_count = 0
            self.shiftreg_fifo = len(self.read_fifo)
            self.shiftreg_console = min(len(self.console_fifo), 255)
            self.shiftreg_debug = 0x12345678
        if update and old["dsel"] and ir == 2:
            self.write_vector = self.shiftreg_write
        self.avm()

    def avm(self):
        """The memory side runs much faster than TCK, so it drains at once."""
        while self.pending_reads and len(self.read_fifo) < 128:
            self.read_fifo.append(self.pending_reads.pop(0))
        while self.write_fifo:
            word = self.write_fifo.pop(0)
            cmd, byte = word >> 8, word & 0xFF
            if cmd in (0x0, 0x8):
                if self.write_enabled:
                    self.write_data[self.byte_count] = byte
                    self.byte_count += 1
                    if self.byte_count == 4:
                        self.memory[self.address] = bytes(self.write_data)
                        self.byte_count = 0
                        if self.incrementing:
                            self.address += 4
            elif cmd == 0x1:
                self.byte_count, self.write_enabled = 0, 1
                self.incrementing = byte >> 7
            elif cmd in (0x2, 0x3):
                self.write_enabled = 0
                for i in range(byte + 1):
                    addr = self.address + (4 * i if cmd == 3 else 0)
                    self.pending_reads.extend(self.memory.get(addr, b"\xee" * 4))
                if cmd == 3:
                    self.address += 4 * (byte + 1)
                while self.pending_reads and len(self.read_fifo) < 128:
                    self.read_fifo.append(self.pending_reads.pop(0))
            elif 0x4 <= cmd <= 0x7:
                self.write_enabled = 0
                shift = 8 * (cmd - 4)
                self.address = (self.address & ~(0xFF << shift)) | (byte << shift)


class ArtixModel:
    IDCODE = 0x1362C093          # revision 1 XC7A50T

    def __init__(self):
        self.state = TLR
        self.ir = jt.IR_IDCODE
        self.ir_shift = 0
        self.dr = 0
        self.dr_len = 32
        self.memory = {}
        self.chain = UserChainModel(self.memory)
        self.presented = 1
        self.config_bits = []
        self.configured = True
        self.jprogram = False

    def presented_tdo(self):
        if self.state == SH_IR:
            return self.ir_shift & 1
        if self.state == SH_DR:
            if self.ir == jt.IR_USER4 and self.configured:
                return self.chain.tdo()
            return self.dr & 1
        return 1

    def rising(self, tms, tdi):
        sampled = self.presented
        state = self.state
        if state == CAP_IR:
            capture = 0x01 | (jt.IR_CAPTURE_INIT) | (jt.IR_CAPTURE_DONE if self.configured else 0)
            self.ir_shift = capture
        elif state == SH_IR:
            self.ir_shift = (tdi << (jt.IR_LENGTH - 1)) | (self.ir_shift >> 1)
        elif state == UPD_IR:
            self.ir = self.ir_shift & 0x3F
            if self.ir == jt.IR_JPROGRAM:
                self.configured, self.jprogram, self.config_bits = False, True, []
            if self.ir == jt.IR_JSTART and self.config_bits:
                self.configured = True
        elif state == CAP_DR:
            if self.ir == jt.IR_IDCODE:
                self.dr, self.dr_len = self.IDCODE, 32
            else:
                self.dr, self.dr_len = 0, 1
        elif state == SH_DR:
            if self.ir == jt.IR_CFG_IN:
                self.config_bits.append(tdi)
            self.dr = (tdi << (self.dr_len - 1)) | (self.dr >> 1)
        user = self.ir == jt.IR_USER4 and self.configured
        self.chain.edge(user and state not in (TLR,), user and state == CAP_DR,
                        user and state == SH_DR, user and state == UPD_DR, tdi)
        self.state = NEXT[state][tms]
        if self.state == TLR:
            self.ir = jt.IR_IDCODE
        self.presented = self.presented_tdo()
        return sampled


class FakeFtdi:
    """Executes MPSSE command streams against an ArtixModel."""

    def __init__(self, model):
        self.model = model
        self.tms = 1
        self.tdi = 0
        self.out = bytearray()
        self.closed = False
        self.pins = None

    def clock(self, tdi=None, tms=None):
        if tdi is not None:
            self.tdi = tdi
        if tms is not None:
            self.tms = tms
        return self.model.rising(self.tms, self.tdi)

    def write_data(self, data):
        data, i = bytes(data), 0
        while i < len(data):
            op = data[i]
            if op in (0x19, 0x39, 0x11):
                n = data[i + 1] + (data[i + 2] << 8) + 1
                payload = data[i + 3:i + 3 + n]
                for byte in payload:
                    got = 0
                    for b in range(8):
                        bit = (byte >> (7 - b)) & 1 if op == 0x11 else (byte >> b) & 1
                        got |= self.clock(tdi=bit) << b
                    if op == 0x39:
                        self.out.append(got)
                i += 3 + n
            elif op in (0x1B, 0x3B, 0x13):
                n, byte = data[i + 1] + 1, data[i + 2]
                got = 0
                for b in range(n):
                    bit = (byte >> (7 - b)) & 1 if op == 0x13 else (byte >> b) & 1
                    got = (got >> 1) | (self.clock(tdi=bit) << 7)
                if op == 0x3B:
                    self.out.append(got)
                i += 3
            elif op in (0x4B, 0x6B):
                n, byte = data[i + 1] + 1, data[i + 2]
                got = 0
                for b in range(n):
                    got = (got >> 1) | (self.clock(tdi=byte >> 7, tms=(byte >> b) & 1) << 7)
                if op == 0x6B:
                    self.out.append(got)
                i += 3
            elif op == 0x8E:
                for _ in range(data[i + 1] + 1):
                    self.clock()
                i += 2
            elif op == 0x8F:
                for _ in range(8 * (data[i + 1] + (data[i + 2] << 8) + 1)):
                    self.clock()
                i += 3
            elif op == 0x80:
                self.pins = (data[i + 1], data[i + 2])
                i += 3
            elif op in (0x85, 0x87):
                i += 1
            else:
                raise AssertionError(f"unexpected MPSSE opcode 0x{op:02X}")

    def read_data_bytes(self, size, attempt=1):
        data, self.out = self.out[:size], self.out[size:]
        return data

    def close(self, freeze=False):
        self.closed = True
        self.frozen = freeze


def board(model=None):
    model = model or ArtixModel()
    ftdi = FakeFtdi(model)
    return jt.Board(mpsse=jt.Mpsse(ftdi)), model, ftdi


class TapTest(unittest.TestCase):
    def test_idcode_and_identify(self):
        b, _, _ = board()
        self.assertEqual(b.identify(), 0x1362C093)
        self.assertEqual((b.part, b.bitstream), ("XC7A50T", "u64e2_50t.bit"))

    def test_bypass_delay_is_one_device(self):
        b, _, _ = board()
        self.assertEqual(b.tap.bypass_delay(), 1)

    def test_lattice_is_refused(self):
        model = ArtixModel()
        model.IDCODE = 0x41111043
        b, _, _ = board(model)
        with self.assertRaisesRegex(jt.JtagError, "LFE5U"):
            b.identify()

    def test_unpowered_is_refused(self):
        model = ArtixModel()
        model.IDCODE = 0xFFFFFFFF
        b, _, _ = board(model)
        with self.assertRaisesRegex(jt.JtagError, "no device answers"):
            b.identify()

    def test_release_leaves_pins_inputs(self):
        b, _, ftdi = board()
        b.close()
        self.assertEqual(ftdi.pins, (0, 0))
        self.assertTrue(ftdi.frozen)


class UserChainTest(unittest.TestCase):
    def test_user_id(self):
        b, _, _ = board()
        self.assertEqual(b.chain.user_id(), jt.USER_ID_VALUE)

    def test_outputs(self):
        b, model, _ = board()
        b.chain.set_outputs(0x80)
        self.assertEqual(model.chain.write_vector, 0x80)
        b.chain.set_outputs(0)
        self.assertEqual(model.chain.write_vector, 0)

    def test_write_then_read(self):
        b, model, _ = board()
        data = bytes((i * 7 + 3) & 0xFF for i in range(4096))
        b.chain.write(0x30000, data)
        self.assertEqual(model.chain.lost_writes, 0)
        self.assertEqual(model.memory[0x30000], data[:4])
        self.assertEqual(model.memory[0x30FFC], data[-4:])
        self.assertEqual(b.chain.read(0x30000, len(data)), data)

    def test_read_spans_commands(self):
        b, model, _ = board()
        for i in range(600):
            model.memory[0x1000 + 4 * i] = struct.pack("<L", i * 0x01010101 & 0xFFFFFFFF)
        got = b.chain.read(0x1000, 2400)
        self.assertEqual(got, b"".join(model.memory[0x1000 + 4 * i] for i in range(600)))

    def test_console(self):
        b, model, _ = board()
        text = b"Hello world, U64-II!\nMagic!\n" * 20
        model.chain.console_fifo.extend(text)
        sink = io.StringIO()
        b.console(0.3, sink)
        self.assertEqual(sink.getvalue().encode("latin-1"), text)


class FlowTest(unittest.TestCase):
    def test_run_application(self):
        b, model, _ = board()
        b.identify()
        image = bytes(range(256)) * 200 + b"\x01\x02"
        b.run_application(image)
        padded = image + b"\x00\x00"
        for off in range(0, len(padded), 4):
            self.assertEqual(model.memory[jt.APP_ADDRESS + off], padded[off:off + 4])
        jump = struct.unpack("<L", model.memory[0xFFF8])[0]
        self.assertEqual(model.memory[0xFFFC], struct.pack("<L", jt.BOOT_MAGIC_VALUE))
        # The boot request points at the cache flush, 2 KB aligned.
        self.assertEqual(jump, jt.TRAMPOLINE_ADDRESS)
        self.assertEqual(jump % jt.ICACHE_BYTES, 0)
        words = [struct.unpack("<L", model.memory[jump + 4 * i])[0] for i in range(514)]
        self.assertEqual(words[:512], [jt.RISCV_NOP] * 512)
        self.assertEqual(words[512:], [0x000302B7, 0x00028067])   # lui t0,0x30; jalr x0,0(t0)
        self.assertEqual(model.chain.write_vector, 0)

    def test_trampoline_reaches_unaligned_targets(self):
        for target in (0x30000, 0x30800, 0x12345678 & ~3):
            words = struct.unpack("<514L", jt.Board.cache_flush_trampoline(target))
            lui, jalr = words[512], words[513]
            upper = lui & 0xFFFFF000
            imm = jalr >> 20
            imm -= (imm & 0x800) << 1
            self.assertEqual((upper + imm) & 0xFFFFFFFF, target)

    def test_failed_load_boots_flash_through_flush(self):
        b, model, _ = board()
        real_read = b.chain.read
        # Verifying the image fails; the cache flush and boot request verify.
        b.chain.read = lambda address, length: (
            bytes(length) if address >= jt.APP_ADDRESS else real_read(address, length))
        with self.assertRaises(jt.JtagError):
            b.run_application(b"\x13\x00\x00\x00" * 16)
        b.chain.read = real_read
        self.assertEqual(model.chain.write_vector, 0)            # CPU released
        self.assertEqual(model.memory[0xFFF8], struct.pack("<L", jt.TRAMPOLINE_ADDRESS))
        tail = struct.unpack("<L", model.memory[jt.TRAMPOLINE_ADDRESS + 4 * 512])[0]
        self.assertEqual(tail, 0x800002B7)                       # back into the bootloader

    def test_lattice_refused_before_any_ir_scan(self):
        model = ArtixModel()
        model.IDCODE = 0x41111043
        b, _, _ = board(model)
        scans = []
        real_ir = b.tap.ir
        b.tap.ir = lambda *a, **k: scans.append(a) or real_ir(*a, **k)
        with self.assertRaises(jt.JtagError):
            b.identify()
        self.assertEqual(scans, [])

    def test_reset_flushes_then_reenters_bootloader(self):
        b, model, _ = board()
        b.reset_cpu()
        self.assertEqual(model.memory[0xFFF8], struct.pack("<L", jt.TRAMPOLINE_ADDRESS))
        self.assertEqual(model.memory[0xFFFC], struct.pack("<L", jt.BOOT_MAGIC_VALUE))
        tail = [struct.unpack("<L", model.memory[jt.TRAMPOLINE_ADDRESS + 4 * i])[0]
                for i in (512, 513)]
        self.assertEqual(tail, [0x800002B7, 0x00028067])       # lui t0,0x80000; jalr x0,0(t0)
        self.assertEqual(model.chain.write_vector, 0)

    def test_configure_sends_bitstream_msb_first(self):
        b, model, _ = board()
        b.identify()
        body = b"\xff" * 16 + b"\xaa\x99\x55\x66" + bytes(range(64))
        with tempfile.NamedTemporaryFile(suffix=".bit") as handle:
            handle.write(body)
            handle.flush()
            b.configure(handle.name)
        bits = model.config_bits
        sent = bytes(sum(bits[i + k] << (7 - k) for k in range(8))
                     for i in range(0, len(bits), 8))
        self.assertEqual(sent, body)
        self.assertTrue(model.configured)

    def test_main_probe(self):
        model = ArtixModel()
        rc = jt.main(["probe"], mpsse=jt.Mpsse(FakeFtdi(model)))
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
