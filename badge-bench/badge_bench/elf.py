"""ELF loading and symbol lookup."""
import bisect

from elftools.elf.elffile import ELFFile

SHF_EXECINSTR = 0x4


class BenchError(Exception):
    """A setup problem (bad ELF, missing symbol, bad argument): exit 1."""


class CartElf:
    def __init__(self, path):
        self.path = path
        try:
            with open(path, 'rb') as fh:
                self.raw = fh.read()
        except OSError as e:
            raise BenchError(f"cannot read {path}: {e.strerror}")
        import io
        try:
            self.elf = ELFFile(io.BytesIO(self.raw))
        except Exception as e:  # pyelftools raises several types
            raise BenchError(f"{path} is not an ELF file ({e})")
        if self.elf['e_machine'] != 'EM_ARM':
            raise BenchError(f"{path} is not an ARM ELF (e_machine {self.elf['e_machine']})")
        symtab = self.elf.get_section_by_name('.symtab')
        if symtab is None:
            raise BenchError(f"{path} has no symbol table (stripped?)")
        self.syms = {}      # name -> (value, size, type)
        by_addr = {}        # (addr, size) -> [names] for sized functions
        data = []
        for s in symtab.iter_symbols():
            if not s.name:
                continue
            t = s['st_info']['type']
            self.syms[s.name] = (s['st_value'], s['st_size'], t)
            if t == 'STT_FUNC' and s['st_size']:
                by_addr.setdefault((s['st_value'] & ~1, s['st_size']), []).append(s.name)
            elif t == 'STT_OBJECT':
                data.append((s['st_value'], s['st_size'], s.name))
        # Functions: (addr, size, name), aliases at one address joined with " = ".
        self.funcs = sorted((a, z, ' = '.join(sorted(n))) for (a, z), n in by_addr.items())
        self._func_starts = [f[0] for f in self.funcs]
        self.objects = sorted(data)
        self._obj_starts = [o[0] for o in self.objects]
        self.exec_sections = [(s['sh_addr'], s.data()) for s in self.elf.iter_sections()
                              if s['sh_flags'] & SHF_EXECINSTR and s['sh_type'] == 'SHT_PROGBITS']

    def segments(self):
        """[(vaddr, data, memsz)] of the PT_LOAD segments."""
        return [(seg['p_vaddr'], seg.data(), seg['p_memsz']) for seg in self.elf.iter_segments()
                if seg['p_type'] == 'PT_LOAD']

    def need(self, name):
        if name not in self.syms:
            raise BenchError(f"symbol '{name}' not found in {self.path}")
        return self.syms[name]

    def func_index(self, addr):
        """Index into self.funcs of the sized function containing addr, or None."""
        i = bisect.bisect_right(self._func_starts, addr) - 1
        if i >= 0 and addr < self.funcs[i][0] + self.funcs[i][1]:
            return i
        return None

    def describe_code(self, addr):
        """'name+0xoff' for a code address (nearest preceding function if outside one)."""
        i = self.func_index(addr)
        if i is not None:
            a, _, n = self.funcs[i]
            return f"{n}+{addr - a:#x}"
        i = bisect.bisect_right(self._func_starts, addr) - 1
        if i >= 0:
            a, z, n = self.funcs[i]
            return f"after {n} (+{addr - a:#x}, function is {z} bytes)"
        return "no symbol"

    def describe_data(self, addr):
        i = bisect.bisect_right(self._obj_starts, addr) - 1
        if i >= 0:
            a, z, n = self.objects[i]
            if addr < a + max(z, 1):
                return f"{n}+{addr - a:#x}"
            return f"after {n} ({z} bytes at {a:#010x})"
        return "no symbol"

    def code_bytes(self, addr, size):
        for base, data in self.exec_sections:
            if base <= addr and addr + size <= base + len(data):
                return data[addr - base: addr - base + size]
        return None
