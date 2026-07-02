import pytest

from src.risk import CircuitBreaker, CircuitBreakerTripped, position_size


def test_position_size_risks_exact_pct_of_equity():
    equity = 100_000.0
    risk_pct = 0.01
    entry, stop = 50_000.0, 49_000.0  # 1000 risk per unit

    qty = position_size(equity, risk_pct, entry, stop)

    dollar_risk_if_stopped = qty * abs(entry - stop)
    assert dollar_risk_if_stopped == pytest.approx(equity * risk_pct)


def test_position_size_rejects_zero_distance_stop():
    with pytest.raises(ValueError):
        position_size(100_000.0, 0.01, 50_000.0, 50_000.0)


def test_circuit_breaker_does_not_trip_under_threshold():
    breaker = CircuitBreaker(historical_max_dd_pct=0.10, multiplier=1.5)  # threshold = 15%
    breaker.update(100_000)
    dd = breaker.update(87_000)  # 13% drawdown, below 15% threshold
    assert dd == pytest.approx(0.13)
    assert breaker.halted is False


def test_circuit_breaker_trips_at_1_5x_historical_max_dd():
    breaker = CircuitBreaker(historical_max_dd_pct=0.10, multiplier=1.5)  # threshold = 15%
    breaker.update(100_000)
    with pytest.raises(CircuitBreakerTripped, match="CRITICAL FAILSAFE TRIPPED"):
        breaker.update(84_000)  # 16% drawdown, breaches 15% threshold


def test_circuit_breaker_stays_halted_until_manual_reset():
    breaker = CircuitBreaker(historical_max_dd_pct=0.10, multiplier=1.5)
    breaker.update(100_000)
    with pytest.raises(CircuitBreakerTripped):
        breaker.update(80_000)

    with pytest.raises(CircuitBreakerTripped):
        breaker.update(100_000)  # even a full equity recovery must not silently un-halt

    breaker.reset()
    assert breaker.halted is False
    assert breaker.update(100_000) == 0.0


def test_circuit_breaker_rejects_nonpositive_baseline():
    with pytest.raises(ValueError):
        CircuitBreaker(historical_max_dd_pct=0.0)
