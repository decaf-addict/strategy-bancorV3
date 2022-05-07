import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0x514910771AF9Ca656af840dff83E8264EcF986CA"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x98C63b7B319dFBDF3d811530F2ab9DfE4983Af9D", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def from_gov(gov):
    yield {'from': gov}


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token, from_gov):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management, from_gov)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy_factory(strategist, keeper, vault, StrategyFactory, gov):
    factory = strategist.deploy(StrategyFactory, vault)
    yield factory


@pytest.fixture
def tradeFactory():
    yield Contract("0x7BAF843e06095f68F4990Ca50161C2C4E4e01ec6")


@pytest.fixture
def yMechs():
    yield Contract("0x2C01B4AD51a67E2d8F02208F54dF9aC4c0B778B6")


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, strategy_factory, gov, tradeFactory, yMechs, chain, from_gov):
    strategy = Strategy.at(strategy_factory.original(), owner=gov)
    strategy.setKeeper(keeper, {"from": gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, from_gov)
    tradeFactory.grantRole(
        tradeFactory.STRATEGY(), strategy, {"from": yMechs, "gas_price": "0 gwei"}
    )
    strategy.setTradeFactory(tradeFactory, from_gov)
    chain.sleep(1)
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
