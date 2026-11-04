import math

import pytest

from app.robot import (
    AMBIENT_TEMP,
    BATTERY_IDLE_DRAIN,
    BATTERY_LOAD_DRAIN,
    DEADMAN_TIMEOUT,
    MAX_SPEED,
    TEMP_PER_LOAD,
    RobotSimulator,
)


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def sim(clock):
    return RobotSimulator(clock=clock, wall_clock=lambda: 1730551234.6)


def hold(sim, clock, linear, angular, seconds, period=0.05):
    """Simulate a held stick: commands at 20 Hz for ``seconds``."""
    for _ in range(int(round(seconds / period))):
        sim.command(linear, angular)
        clock.advance(period)


def test_initial_telemetry_shape(sim):
    t = sim.telemetry()
    assert t == {
        "type": "telemetry",
        "speed": 0.0,
        "battery": 100.0,
        "temperature": AMBIENT_TEMP,
        "linear": 0.0,
        "angular": 0.0,
        "ts": 1730551234600,
    }


@pytest.mark.parametrize(
    "given,expected",
    [((2.0, -3.0), (1.0, -1.0)), ((0.42, -0.1), (0.42, -0.1)), ((math.nan, math.inf), (0.0, 0.0))],
)
def test_command_is_clamped(sim, given, expected):
    assert sim.command(*given) == expected
    t = sim.telemetry()
    assert (t["linear"], t["angular"]) == expected


def test_deadman_zeroes_command_after_timeout(sim, clock):
    sim.command(0.8, 0.3)
    clock.advance(DEADMAN_TIMEOUT - 0.01)
    assert sim.telemetry()["linear"] == 0.8
    clock.advance(0.02)
    t = sim.telemetry()
    assert t["linear"] == 0.0 and t["angular"] == 0.0


def test_regular_commands_keep_robot_moving(sim, clock):
    hold(sim, clock, 1.0, 0.0, 3.0)
    assert sim.telemetry()["linear"] == 1.0


def test_speed_converges_to_target_with_lag(sim, clock):
    sim.command(0.5, 0.0)
    clock.advance(0.1)
    early = sim.telemetry()["speed"]
    assert 0 < early < 0.5 * MAX_SPEED  # lag: not instant
    hold(sim, clock, 0.5, 0.0, 6.0)
    assert sim.telemetry()["speed"] == pytest.approx(0.5 * MAX_SPEED, abs=0.01)


def test_speed_uses_absolute_linear_and_decays_after_release(sim, clock):
    hold(sim, clock, -1.0, 0.0, 6.0)
    assert sim.telemetry()["speed"] == pytest.approx(MAX_SPEED, abs=0.01)
    clock.advance(10.0)  # stick released -> dead-man -> target 0
    assert sim.telemetry()["speed"] == pytest.approx(0.0, abs=0.01)


def test_speed_never_exceeds_max(sim, clock):
    for _ in range(400):
        sim.command(5.0, 5.0)
        clock.advance(0.05)
        assert 0.0 <= sim.telemetry()["speed"] <= MAX_SPEED


def test_lazy_integration_splits_at_deadman_deadline(sim, clock):
    """One big step must equal holding the command for exactly the timeout."""
    sim.command(1.0, 0.0)
    clock.advance(30.0)
    t = sim.telemetry()
    drain = (BATTERY_IDLE_DRAIN + BATTERY_LOAD_DRAIN) * DEADMAN_TIMEOUT + BATTERY_IDLE_DRAIN * 29.5
    assert t["battery"] == pytest.approx(100.0 - drain, abs=0.01)


def test_battery_drain_rates(sim, clock):
    clock.advance(100.0)
    assert sim.telemetry()["battery"] == pytest.approx(100.0 - BATTERY_IDLE_DRAIN * 100, abs=0.01)
    hold(sim, clock, 0.0, 1.0, 10.0)  # angular-only still counts as load
    expected = 99.0 - (BATTERY_IDLE_DRAIN + BATTERY_LOAD_DRAIN) * 10
    assert sim.telemetry()["battery"] == pytest.approx(expected, abs=0.02)


def test_battery_recharges_at_five_percent_and_stays_in_bounds(clock):
    sim = RobotSimulator(clock=clock, battery=5.5)
    for _ in range(200):
        sim.command(1.0, 1.0)
        clock.advance(0.05)
        b = sim.telemetry()["battery"]
        assert 5.0 <= b <= 100.0
    assert sim.telemetry()["battery"] > 90.0  # it wrapped around to ~100


def test_temperature_approaches_load_target_and_stays_bounded(sim, clock):
    for _ in range(1200):  # 60 s at full load
        sim.command(1.0, 0.0)
        clock.advance(0.05)
        t = sim.telemetry()["temperature"]
        assert AMBIENT_TEMP <= t <= AMBIENT_TEMP + TEMP_PER_LOAD
    assert sim.telemetry()["temperature"] == pytest.approx(AMBIENT_TEMP + TEMP_PER_LOAD, abs=0.1)
    clock.advance(120.0)
    assert sim.telemetry()["temperature"] == pytest.approx(AMBIENT_TEMP, abs=0.1)


def test_temperature_uses_max_of_linear_and_angular(sim, clock):
    hold(sim, clock, 0.2, -0.6, 80.0)
    assert sim.telemetry()["temperature"] == pytest.approx(
        AMBIENT_TEMP + TEMP_PER_LOAD * 0.6, abs=0.1
    )
