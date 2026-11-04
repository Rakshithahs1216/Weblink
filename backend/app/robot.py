"""Shared robot simulator (ARCHITECTURE.md section 6).

The model is integrated lazily and exactly: every read or command first advances
the state to "now". Between commands the inputs are piecewise constant, so the
first-order lags have closed-form solutions and no background task is needed.
"""

from __future__ import annotations

import math
import time
from collections.abc import Callable

MAX_SPEED = 1.5  # m/s at |linear| == 1
DEADMAN_TIMEOUT = 0.5  # s without joystick input -> command forced to zero
SPEED_TAU = 0.6  # s, speed lag time constant
TEMP_TAU = 8.0  # s, temperature lag time constant
AMBIENT_TEMP = 30.0
TEMP_PER_LOAD = 15.0
BATTERY_IDLE_DRAIN = 0.01  # %/s
BATTERY_LOAD_DRAIN = 0.15  # %/s at load 1
BATTERY_RECHARGE_AT = 5.0
BATTERY_FULL = 100.0


def clamp_unit(value: float) -> float:
    """Clamp to [-1, 1]; non-finite values become 0."""
    if not math.isfinite(value):
        return 0.0
    return max(-1.0, min(1.0, value))


class RobotSimulator:
    def __init__(
        self,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        battery: float = BATTERY_FULL,
        temperature: float = AMBIENT_TEMP,
    ):
        self._clock = clock
        self._wall_clock = wall_clock
        self.speed = 0.0
        self.battery = battery
        self.temperature = temperature
        self.linear = 0.0
        self.angular = 0.0
        self._last_step = clock()
        self._last_command: float | None = None  # clock time of last joystick input

    @property
    def load(self) -> float:
        return max(abs(self.linear), abs(self.angular))

    def command(self, linear: float, angular: float) -> tuple[float, float]:
        """Apply a joystick command; returns the clamped values actually used."""
        self.step()
        self.linear = clamp_unit(linear)
        self.angular = clamp_unit(angular)
        self._last_command = self._clock()
        return self.linear, self.angular

    def step(self) -> None:
        now = self._clock()
        if now <= self._last_step:
            return
        if self._last_command is not None:
            deadline = self._last_command + DEADMAN_TIMEOUT
            if now >= deadline:
                if deadline > self._last_step:
                    self._integrate(deadline - self._last_step)
                    self._last_step = deadline
                self.linear = self.angular = 0.0
                self._last_command = None
        self._integrate(now - self._last_step)
        self._last_step = now

    def _integrate(self, dt: float) -> None:
        if dt <= 0:
            return
        load = self.load
        speed_target = abs(self.linear) * MAX_SPEED
        self.speed += (speed_target - self.speed) * (1.0 - math.exp(-dt / SPEED_TAU))
        temp_target = AMBIENT_TEMP + TEMP_PER_LOAD * load
        self.temperature += (temp_target - self.temperature) * (1.0 - math.exp(-dt / TEMP_TAU))
        self.battery -= (BATTERY_IDLE_DRAIN + BATTERY_LOAD_DRAIN * load) * dt
        while self.battery <= BATTERY_RECHARGE_AT:  # demo: instant recharge
            self.battery += BATTERY_FULL - BATTERY_RECHARGE_AT

    def telemetry(self) -> dict:
        """Current state as the contract's ``telemetry`` message."""
        self.step()
        return {
            "type": "telemetry",
            "speed": round(self.speed, 3),
            "battery": round(self.battery, 2),
            "temperature": round(self.temperature, 2),
            "linear": round(self.linear, 3),
            "angular": round(self.angular, 3),
            "ts": int(self._wall_clock() * 1000),
        }
