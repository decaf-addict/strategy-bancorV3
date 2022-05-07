// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";
import "../interfaces/Bancor/IBancorNetwork.sol";
import "../interfaces/Bancor/IPoolCollection.sol";
import "../interfaces/Bancor/IPendingWithdrawals.sol";
import "../interfaces/Bancor/IStandardRewards.sol";

interface ITradeFactory {
    function enable(address, address) external;

    function disable(address, address) external;
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IBancorNetwork public constant bancor = IBancorNetwork(0xeEF417e1D5CC832e619ae18D2F140De2999dD4fB);
    IStandardRewards public constant standardRewards = IStandardRewards(0xb0B958398ABB0b5DB4ce4d7598Fb868f5A00f372);
    IPendingWithdrawals public constant pendingWithdrawals = IPendingWithdrawals(0x857Eb0Eb2572F7092C417CD386BA82e45EbA9B8a);
    IPoolCollection public poolCollection;
    IPoolToken public poolToken;
    IERC20[] public lmRewards;
    Toggles public toggles;
    ITradeFactory public tradeFactory;
    uint256 public currentProgramId;

    modifier isVaultManager {
        checkVaultManagers();
        _;
    }

    function checkVaultManagers() internal {
        require(msg.sender == vault.governance() || msg.sender == vault.management());
    }

    struct Toggles {
        bool lossWarningOn; // first line of defense
        bool realizeLossOn;
    }

    constructor(address _vault) public BaseStrategy(_vault) {
        _initializeStrat(_vault);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_vault);
    }

    function _initializeStrat(address _vault) internal {
        poolCollection = bancor.collectionByPool(want);
        poolToken = poolCollection.poolToken(want);
        want.safeApprove(address(standardRewards), type(uint256).max);
        want.approve(address(bancor), type(uint256).max);
        poolToken.approve(address(bancor), type(uint256).max);
        poolToken.approve(address(pendingWithdrawals), type(uint256).max);
        currentProgramId = standardRewards.latestProgramId(address(want));
    }


    function name() external view override returns (string memory) {
        return
        string(
            abi.encodePacked(
                "StrategyBancor",
                IERC20Metadata(address(want)).symbol()
            )
        );
    }

    /// tokens pending withdrawals are actually send to the pendingWithdarwal contract so must be accounted for separately
    function estimatedTotalAssets() public view override returns (uint256) {
        (,uint totalPending) = withdrawalRequestsInfo();
        return balanceOfWant().add(valueOfTotalPoolTokens()).add(totalPending);
    }

    /// This strategy's accounting is a little different because funds are not liquid.
    /// On harvest it'll try to pay debt with loose wants only
    /// losses are not realized unless toggled on
    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssets = estimatedTotalAssets();
        uint256 liquidWants = balanceOfWant();
        _debtPayment = Math.min(liquidWants, _debtOutstanding);

        if (totalAssets > totalDebt) {
            // if there are any remaining wants, consider them as profit
            uint256 estimatedProfits = totalAssets.sub(totalDebt);
            // pay debts first, any remaining go to profit
            uint256 remainingWants = liquidWants > _debtPayment ? liquidWants.sub(_debtPayment) : 0;
            _profit = Math.min(estimatedProfits, remainingWants);

        } else {
            if (toggles.lossWarningOn) {
                // this allows us to decide case-by-case whether we want to realize loss or not
                revert("loss!");
            } else if (toggles.realizeLossOn) {
                _loss = totalDebt.sub(totalAssets);
                _debtPayment = Math.min(_debtPayment, _debtOutstanding.sub(_loss));
            } else {
                // this scenario is when there's loss but we defer it to the the remaining funds instead of realizing it
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        _claimReward();
        uint256 _balanceOfWant = balanceOfWant();

        if (_balanceOfWant > _debtOutstanding) {
            uint256 _amountToInvest = _balanceOfWant - _debtOutstanding;

            Pool memory poolData = poolCollection.poolData(want);
            uint256 depositLimit = poolData.depositLimit;
            uint256 stakedBalance = poolData.liquidity.stakedBalance;
            uint256 investable = depositLimit >= stakedBalance ? depositLimit.sub(stakedBalance) : 0;
            _amountToInvest = Math.min(investable, _amountToInvest);
            emit Debug("depositLimit", depositLimit);
            emit Debug("stakedBalance", stakedBalance);

            emit Debug("_amount", _amountToInvest);
            if (_amountToInvest > 0 && currentProgramId != 0 && standardRewards.isProgramActive(currentProgramId) && standardRewards.isProgramEnabled(currentProgramId)) {
                standardRewards.depositAndJoin(currentProgramId, _amountToInvest);
            }
        }
    }

    event Debug(string msg);
    event Debug(string msg, uint val);

    /* NOTE: Bancor has a waiting period for withdrawals. We need to first request
             a withdrawal, at which point we recieve a withdrawal request ID. 7 days later,
             we can complete the withdrawal with this ID. */
    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        revert("disabled!");
    }

    function liquidateAllPositions() internal override returns (uint256) {
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstake(balanceOfStakedPoolToken());
        // cancel all pendingwithdrawals
        uint256[] memory ids = pendingWithdrawals.withdrawalRequestIds(address(this));
        for (uint8 i = 0; i < ids.length; i++) {
            _cancelWithdrawal(ids[i], false);
            lmRewards[i].transfer(_newStrategy, balanceOfReward(i));
        }
        poolToken.transfer(_newStrategy, balanceOfPoolToken());
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256){}

    // ----------------- SUPPORT & UTILITY FUNCTIONS ----------

    /// normally StandardRewards.depositAndJoin() is used. This is here for composability
    function deposit(uint256 _amountWants) external isVaultManager {
        bancor.deposit(want, _amountWants);
    }

    function stake(uint256 _amountPoolTokens) external isVaultManager {
        _stake(_amountPoolTokens);
    }

    function _stake(uint256 _amountPoolTokens) internal {
        standardRewards.join(currentProgramId, _amountPoolTokens);
    }

    function unstake(uint256 _amountPoolTokens) external isVaultManager {
        _unstake(_amountPoolTokens);
    }

    function _unstake(uint256 _amountPoolTokens) internal {
        standardRewards.leave(currentProgramId, _amountPoolTokens);
    }

    function requestWithdrawal(uint256 _poolTokenAmount, bool _unstakeFromRewards) external isVaultManager {
        _requestWithdrawal(_poolTokenAmount, _unstakeFromRewards);
    }

    function _requestWithdrawal(uint256 _poolTokenAmount, bool _unstakeFromRewards) internal {
        if (_unstakeFromRewards) {
            _unstake(_poolTokenAmount);
        }
        bancor.initWithdrawal(poolToken, _poolTokenAmount);
    }

    function completeWithdrawal(uint256 _withdrawalID) external isVaultManager {
        _completeWithdrawal(_withdrawalID);
    }

    function _completeWithdrawal(uint256 _withdrawalID) internal {
        require(pendingWithdrawals.isReadyForWithdrawal(_withdrawalID), "!ready");
        bancor.withdraw(_withdrawalID);
    }

    function cancelWithdrawal(uint256 _withdrawalID, bool _restake) external isVaultManager {
        _cancelWithdrawal(_withdrawalID, _restake);
    }

    /// if canceled, bnTokens need to be re-entered into rewards
    function _cancelWithdrawal(uint256 _withdrawalID, bool _restake) internal {
        bancor.cancelWithdrawal(_withdrawalID);
        if (_restake) {
            _stake(balanceOfPoolToken());
        }
    }

    function claimReward() external isVaultManager {
        _claimReward();
    }

    function _claimReward() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = currentProgramId;
        if (standardRewards.pendingRewards(address(this), ids) > 0) {
            standardRewards.claimRewards(ids);
        }
    }

    // _checkAllowance adapted from https://github.com/therealmonoloco/liquity-stability-pool-strategy/blob/1fb0b00d24e0f5621f1e57def98c26900d551089/contracts/Strategy.sol#L316
    function _checkAllowance(
        address _spender,
        address _token,
        uint256 _amount
    ) internal {
        uint256 _currentAllowance = IERC20(_token).allowance(address(this), _spender);
        if (_currentAllowance < _amount) {
            IERC20(_token).safeIncreaseAllowance(
                _spender,
                _amount - _currentAllowance
            );
        } else {
            IERC20(_token).safeDecreaseAllowance(
                _spender,
                _currentAllowance - _amount
            );
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfPoolToken() public view returns (uint256) {
        return poolToken.balanceOf(address(this));
    }

    function balanceOfStakedPoolToken() public view returns (uint256) {
        return standardRewards.providerStake(address(this), currentProgramId);
    }

    function valueOfTotalPoolTokens() public view returns (uint256) {
        return poolCollection.poolTokenToUnderlying(want, balanceOfPoolToken().add(balanceOfStakedPoolToken()));
    }

    /// sum amount of all pending withdrawals
    struct WithdrawRequestInfo {
        uint256 id;
        uint256 expectedWantAmount;
        uint256 poolTokenAmount;
        uint256 timeToMaturation;
    }

    function withdrawalRequestsInfo() public view returns (WithdrawRequestInfo[] memory requestsInfo, uint256 _wants){
        uint256[] memory ids = pendingWithdrawals.withdrawalRequestIds(address(this));
        if (ids.length > 0) {
            requestsInfo = new WithdrawRequestInfo[](ids.length);
            for (uint8 i = 0; i < ids.length; i++) {
                uint256 matureTime = pendingWithdrawals.withdrawalRequest(ids[i]).createdAt + pendingWithdrawals.lockDuration();
                requestsInfo[i] = WithdrawRequestInfo(
                    ids[i],
                    pendingWithdrawals.withdrawalRequest(ids[i]).reserveTokenAmount,
                    pendingWithdrawals.withdrawalRequest(ids[i]).poolTokenAmount,
                    matureTime > now ? matureTime - now : 0
                );
                _wants += pendingWithdrawals.withdrawalRequest(ids[i]).reserveTokenAmount;
            }
        }
    }


    function balanceOfReward(uint8 index) public view returns (uint256){
        return lmRewards[index].balanceOf(address(this));
    }

    /// for bnt and other possible rewards from liquidity mining
    function whitelistRewards(IERC20 _reward) external isVaultManager {
        lmRewards.push(_reward);
        _reward.approve(address(tradeFactory), type(uint256).max);
        tradeFactory.enable(address(_reward), address(want));
    }

    function delistAllRewards() external isVaultManager {
        delete lmRewards;
        _disallowAllRewards();
    }

    function _disallowAllRewards() internal {
        for (uint8 i; i < lmRewards.length; i++) {
            lmRewards[i].safeApprove(address(tradeFactory), 0);
            tradeFactory.disable(address(lmRewards[i]), address(want));
        }
    }

    function setToggles(Toggles memory _toggles) external isVaultManager {
        toggles = _toggles;
    }

    function setTradeFactory(ITradeFactory _tradeFactory) external onlyGovernance {
        tradeFactory = _tradeFactory;
    }

    function disableTradeFactory() external onlyVaultManagers {
        delete tradeFactory;
        _disallowAllRewards();
    }

    /* NOTE: Reward staking has an active program id which might change.
    Override allows control over which program to withdraw from. */
    function overrideProgramId(uint256 _newProgramId) external onlyVaultManagers {
        currentProgramId = _newProgramId;
    }
}
