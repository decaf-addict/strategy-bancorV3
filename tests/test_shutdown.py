from brownie import ZERO_ADDRESS
import pytest


def test_vault_shutdown_can_withdraw(
        chain, token, vault, strategy, user, amount, RELATIVE_APPROX, gov
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
    vault.setEmergencyShutdown(True)
    chain.sleep(1)
    strategy.harvest()
    vault.withdraw(amount, user, 1000, {'from': user})
    assert token.balanceOf(user) >= amount * .995
