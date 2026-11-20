"""Behavioural simulator of an RO-PUF board, for developing the analysis flow
before real measurements exist. The default parameters are plausible assumptions,
NOT measured values; replace them (or use real data) once the RO array works.

Frequency of RO i on one board, for one read at temperature T:
    f_i = f_nom * (1 + layout_i + process_i + gradient_i)      fixed per board
              * (1 + tempco_i * (T - T_ref))                    temperature drift
              * (1 + N(0, sigma_noise))                         per-read jitter
  layout_i   : same on every board (routing differences in the shared bitstream)
  process_i  : random per board and RO (the source of uniqueness)
  gradient_i : random linear gradient across the die, per board

Counts are measured over a fixed window, exactly as the hardware does, and
response bit i = 1 if count[2i] > count[2i+1] (ties give 0).
"""

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class PUFSimConfig:
    n_ro: int = 256
    grid_cols: int = 16
    f_nominal_hz: float = 250e6
    window_s: float = 2 ** 16 / 125e6      # 2^16 cycles of the 125 MHz board clock
    sigma_layout: float = 0.001            # relative, identical on every board
    sigma_process: float = 0.005           # relative, random per board
    sigma_gradient: float = 0.01           # relative, gradient strength across die
    sigma_noise: float = 0.0005            # relative, per read
    tempco_per_c: float = -0.001           # relative frequency change per degree C
    sigma_tempco: float = 0.02             # relative spread of tempco between ROs
    ref_temp_c: float = 40.0               # die temperature at enrolment


class SimulatedBoard:
    _layout_cache = {}

    def __init__(self, seed, config=PUFSimConfig()):
        self.config = config
        rng = np.random.default_rng(seed)
        idx = np.arange(config.n_ro)
        x = (idx % config.grid_cols) / config.grid_cols
        y = (idx // config.grid_cols) / max(1, config.n_ro // config.grid_cols)
        gx, gy = rng.normal(0.0, config.sigma_gradient, size=2)
        self.f_static = config.f_nominal_hz * (
            1.0
            + self._layout(config)
            + rng.normal(0.0, config.sigma_process, config.n_ro)
            + gx * x + gy * y
        )
        self.tempco = config.tempco_per_c * (1.0 + rng.normal(0.0, config.sigma_tempco, config.n_ro))
        self._read_rng = np.random.default_rng([seed, 1])

    @classmethod
    def _layout(cls, config):
        # one fixed pattern shared by all boards (same bitstream)
        if config not in cls._layout_cache:
            rng = np.random.default_rng(12345)
            cls._layout_cache[config] = rng.normal(0.0, config.sigma_layout, config.n_ro)
        return cls._layout_cache[config]

    def counts(self, temp_c=None):
        c = self.config
        if temp_c is None:
            temp_c = c.ref_temp_c
        f = self.f_static * (1.0 + self.tempco * (temp_c - c.ref_temp_c))
        f = f * (1.0 + self._read_rng.normal(0.0, c.sigma_noise, c.n_ro))
        return np.floor(f * c.window_s).astype(np.int64)

    def read(self, temp_c=None):
        counts = self.counts(temp_c)
        return (counts[0::2] > counts[1::2]).astype(np.uint8)
