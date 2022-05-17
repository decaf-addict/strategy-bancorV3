import pytest


def test_revoke_strategy_from_vault(
    chain, token, vault, strategy, amount, user, gov, RELATIVE_APPROX
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # requires manually moving out funds

    strategy.requestWithdrawal(strategy.balanceOfStakedPoolToken(), True)

    # 7 days of cooldown to withdraw
    chain.sleep(3600 * 24 * 7 + 1)
    id = strategy.withdrawalRequestsInfo()[0][0][0]
    strategy.completeWithdrawal(id, True)

    # allow lossy harvest
    strategy.setToggles((False, True, True, True))

    # set emergency and exit
    vault.revokeStrategy(strategy.address, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert token.balanceOf(vault) >= amount * .995

# lossy. Similar to test_operation
def test_emergency_exit(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # requires manually moving out funds

    strategy.requestWithdrawal(strategy.balanceOfStakedPoolToken(), True)

    # 7 days of cooldown to withdraw
    chain.sleep(3600 * 24 * 7 + 1)
    id = strategy.withdrawalRequestsInfo()[0][0][0]
    strategy.completeWithdrawal(id, True)

    # allow lossy harvest
    strategy.setToggles((False, True, True, True))

    # set emergency and exit
    strategy.setEmergencyExit()
    chain.sleep(1)
    strategy.harvest()
    assert token.balanceOf(vault) >= amount * .995
