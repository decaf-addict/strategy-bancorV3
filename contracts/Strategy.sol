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

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IBancorNetwork public constant bancor = IBancorNetwork(0xeEF417e1D5CC832e619ae18D2F140De2999dD4fB);
    IPendingWithdrawals public constant pendingWithdrawals = IPendingWithdrawals(0x857Eb0Eb2572F7092C417CD386BA82e45EbA9B8a);
    IPoolCollection public poolCollection;
    IPoolToken public poolToken;
    IERC20[] public lmRewards;
    Toggles public toggles;

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

    // Bancor gives you an ID for a withdrawal request, so we manage it like this
    uint256 public totalRequestedWithdrawalAmount; // Denominated in bancor pool tokens

    constructor(address _vault) public BaseStrategy(_vault) {
        poolCollection = bancor.collectionByPool(want);
        poolToken = poolCollection.poolToken(want);
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
        return balanceOfWant() + valueOfPoolToken() + balanceOfPendingWithdrawals();
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
                // this scenario is when there's loss but we defer it to the the remaining funds instead of socializing it
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _balanceOfWant = balanceOfWant();

        if (_balanceOfWant > _debtOutstanding) {
            uint256 _amountToInvest = _balanceOfWant - _debtOutstanding;

            Pool memory poolData = poolCollection.poolData(want);
            if (poolData.liquidity.stakedBalance + _amountToInvest > poolData.depositLimit) {
                _amountToInvest = poolData.depositLimit - poolData.liquidity.stakedBalance;
                if (_amountToInvest == 0) return;
            }

            _checkAllowance(address(bancor), address(want), _amountToInvest);
            bancor.deposit(want, _amountToInvest);
        }
    }

    /// Only allow manual exits
    function liquidatePositionManual(uint256 _amountNeeded) external isVaultManager {

    }

    /* NOTE: Bancor has a waiting period for withdrawals. We need to first request
             a withdrawal, at which point we recieve a withdrawal request ID. 7 days later,
             we can complete the withdrawal with this ID. */
    function liquidatePosition(uint256 _amountNeeded)
    internal
    override
    returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 looseWants = balanceOfWant();

    }

    function liquidateAllPositions() internal override returns (uint256) {
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        // cancel all pendingwithdrawals
        uint256[] memory ids = pendingWithdrawals.withdrawalRequestIds(address(this));
        for (uint8 i = 0; i < ids.length; i++) {
            _cancelWithdrawal(ids[i]);
        }

        for (uint8 i = 0; i < ids.length; i++) {
            lmRewards[i].transfer(_newStrategy, balanceOfReward(i));
        }
        poolToken.transfer(_newStrategy, balanceOfPoolToken());

    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256){}

    // ----------------- SUPPORT & UTILITY FUNCTIONS ----------

    function _requestWithdrawal(uint256 _poolTokenAmount) internal {
        uint256 _withdrawalID = bancor.initWithdrawal(poolToken, _poolTokenAmount);

        // min
        _poolTokenAmount = _poolTokenAmount > balanceOfPoolToken() ? balanceOfPoolToken() : _poolTokenAmount;

        // Technically we're losing bits 32-255 in the cast, but this should only matter if more than 4.2B withdrawal requests happen
        totalRequestedWithdrawalAmount += _poolTokenAmount;
    }

    function _withdrawCheck(uint256 _withdrawalID) internal {
        totalRequestedWithdrawalAmount -= pendingWithdrawals.withdrawalRequest(_withdrawalID).poolTokenAmount;
    }

    function _completeWithdrawal(uint256 _withdrawalID) internal {
        _withdrawCheck(_withdrawalID);
        bancor.withdraw(_withdrawalID);
    }

    function _cancelWithdrawal(uint256 _withdrawalID) internal {
        _withdrawCheck(_withdrawalID);
        bancor.cancelWithdrawal(_withdrawalID);
    }

    // _checkAllowance adapted from https://github.com/therealmonoloco/liquity-stability-pool-strategy/blob/1fb0b00d24e0f5621f1e57def98c26900d551089/contracts/Strategy.sol#L316

    function _checkAllowance(
        address _spender,
        address _token,
        uint256 _amount
    ) internal {
        uint256 _currentAllowance = IERC20(_token).allowance(
            address(this),
            _spender
        );
        if (_currentAllowance < _amount) {
            IERC20(_token).safeIncreaseAllowance(
                _spender,
                _amount - _currentAllowance
            );
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfPoolToken() public view returns (uint256) {
        return poolToken.balanceOf(address(this));
    }

    function valueOfPoolToken() public view returns (uint256) {
        return poolCollection.poolTokenToUnderlying(want, balanceOfPoolToken());
    }

    /// sum amount of all pending withdrawals
    function balanceOfPendingWithdrawals() public view returns (uint256 _wants){
        uint256[] memory ids = pendingWithdrawals.withdrawalRequestIds(address(this));
        for (uint8 i = 0; i < ids.length; i++) {
            _wants += pendingWithdrawals.withdrawalRequest(ids[i]).reserveTokenAmount;
        }
    }

    function balanceOfReward(uint8 index) public view returns (uint256){
        return lmRewards[index].balanceOf(address(this));
    }


    /// for bnt and other possible rewards from liquidity mining
    function whitelistRewards(IERC20 _reward) public isVaultManager {
        //        approve trade factory
        //        _reward.approve(, max);
        lmRewards.push(_reward);
    }

    function setToggles(Toggles memory _toggles) public isVaultManager {
        toggles = _toggles;
    }
}
