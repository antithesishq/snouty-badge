"""badge-bench: emulated cycle benchmark for SYCL Badge V2 carts.

Runs a cart's real ELF on an emulated Cortex-M33 (unicorn) with a small
fake of the badge OS, counts every executed instruction and prices it with
a per-instruction cycle model. See README.md; the numbers are a model.
"""
__version__ = "0.1.0"
