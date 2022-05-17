import brownie
from brownie import Contract
import pytest


# lossy operations
def test_operation(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    assert strategy.balanceOfStakedPoolToken() > 0

    # tend()
    strategy.tend()

    strategy.requestWithdrawal(strategy.balanceOfStakedPoolToken(), True)

    # 7 days of cooldown to withdraw
    chain.sleep(3600 * 24 * 7 + 1)
    id = strategy.withdrawalRequestsInfo()[0][0][0]
    strategy.completeWithdrawal(id, True)

    # no withdrawals allowed for strat, only debtPayment
    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    # loss from withdraw fee not covered by lm rewards
    with brownie.reverts("loss!"):
        strategy.harvest({"from": gov})

    strategy.setToggles((False, True, False, True))

    with brownie.reverts():
        vault.withdraw(amount, strategy.address, 1000, {'from': user})

    strategy.setToggles((False, True, True, True))

    vault.withdraw(amount, user, 1000, {'from': user})

    # losses from withdrawal fee + price impact of selling bnt

    assert token.balanceOf(user) >= user_balance_before * 0.9950


def test_profitable_operation(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    assert strategy.balanceOfStakedPoolToken() > 0

    # accrue two weeks of lm rewards
    chain.sleep(3600 * 24 * 14)

    pps_before = vault.pricePerShare()
    strategy.harvest({"from": gov})
    chain.sleep(3600 * 24)
    chain.mine(1)
    assert vault.pricePerShare() > pps_before


def test_profitable_exit(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov, bnt_whale, bnt
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    assert strategy.balanceOfStakedPoolToken() > 0
    # accrue 1m of lm rewards
    chain.sleep(3600 * 24 * 30)
    # seems like rewards cap at a certain amount per epoch, get some help with reward airdrop
    bnt.transfer(strategy, 1000 * 1e18, {'from': bnt_whale})

    strategy.requestWithdrawal(strategy.balanceOfStakedPoolToken(), True)

    # 7 days of cooldown to withdraw
    chain.sleep(3600 * 24 * 7 + 1)
    id = strategy.withdrawalRequestsInfo()[0][0][0]
    strategy.completeWithdrawal(id, True)

    # no withdrawals allowed for strat, only debtPayment
    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})

    # profits from lm rewards should cover any fees
    strategy.harvest({'from': gov})
    vault.withdraw({'from': user})

    assert token.balanceOf(user) >= user_balance_before


def test_change_debt(
        chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, bnt, bnt_whale
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    half = int(amount / 2)

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})

    strategy.requestWithdrawal(vault.debtOutstanding(strategy), True)

    # 7 days of cooldown to withdraw
    chain.sleep(3600 * 24 * 7 + 1)
    id = strategy.withdrawalRequestsInfo()[0][0][0]
    strategy.completeWithdrawal(id, True)

    # allow lossy harvest
    strategy.setToggles((False, True, True, True))

    strategy.harvest({'from': gov})
    vault.withdraw(amount / 2, user, 1000, {'from': user})
    assert token.balanceOf(user) >= amount / 2 * .995

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})

    strategy.requestWithdrawal(vault.debtOutstanding(strategy), True)

    # 7 days of cooldown to withdraw
    chain.sleep(3600 * 24 * 7 + 1)
    id = strategy.withdrawalRequestsInfo()[0][0][0]
    strategy.completeWithdrawal(id, True)

    # instead of the same lossy withdrawal, we test profitable + debtPayment
    # airdrop rewards to test debtPayment + profits
    bnt.transfer(strategy, 1000 * 1e18, {'from': bnt_whale})

    strategy.harvest({'from': gov})
    vault.withdraw({'from': user})
    assert token.balanceOf(user) >= 0


def test_sweep(gov, vault, strategy, token, user, amount, weth, weth_amout):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # TODO: If you add protected tokens to the strategy.
    # Protected token doesn't work
    # with brownie.reverts("!protected"):
    #     strategy.sweep(strategy.protectedToken(), {"from": gov})

    before_balance = weth.balanceOf(gov)
    weth.transfer(strategy, weth_amout, {"from": user})
    assert weth.address != strategy.want()
    assert weth.balanceOf(user) == 0
    strategy.sweep(weth, {"from": gov})
    assert weth.balanceOf(gov) == weth_amout + before_balance


def test_triggers(
        chain, gov, vault, strategy, token, amount, user, weth, weth_amout, strategist
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)
