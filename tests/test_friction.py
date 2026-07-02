import pytest

from src.friction import Side, apply_commission, apply_slippage, round_trip_cost_bps, simulate_fill


def test_slippage_always_worsens_long_entry():
    price = 100.0
    fill = apply_slippage(price, Side.LONG, is_entry=True, slippage_bps=10)
    assert fill > price  # buying long entry -> pay more


def test_slippage_always_worsens_long_exit():
    price = 100.0
    fill = apply_slippage(price, Side.LONG, is_entry=False, slippage_bps=10)
    assert fill < price  # selling to exit long -> receive less


def test_slippage_always_worsens_short_entry():
    price = 100.0
    fill = apply_slippage(price, Side.SHORT, is_entry=True, slippage_bps=10)
    assert fill < price  # selling short entry -> receive less


def test_slippage_always_worsens_short_exit():
    price = 100.0
    fill = apply_slippage(price, Side.SHORT, is_entry=False, slippage_bps=10)
    assert fill > price  # buying to cover short -> pay more


def test_commission_is_nonnegative_and_scales_with_notional():
    assert apply_commission(10_000, 5) == pytest.approx(5.0)
    assert apply_commission(0, 5) == 0


def test_simulate_fill_combines_slippage_and_commission():
    result = simulate_fill(100.0, quantity=10, side=Side.LONG, is_entry=True,
                            slippage_bps=10, commission_bps=5)
    assert result.fill_price > 100.0
    assert result.commission > 0


def test_round_trip_cost_is_double_each_leg():
    assert round_trip_cost_bps(slippage_bps=5, commission_bps=5) == 20
