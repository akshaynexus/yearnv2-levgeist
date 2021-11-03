// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {IERC20, SafeERC20, SafeMath, BaseStrategy, Address} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {IReserveInterestRateStrategy} from "@aave/contracts/interfaces/IReserveInterestRateStrategy.sol";
import {ILendingPool} from "@aave/contracts/interfaces/ILendingPool.sol";
import {IPriceOracle} from "@aave/contracts/interfaces/IPriceOracle.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {IVariableDebtToken} from "@aave/contracts/interfaces/IVariableDebtToken.sol";
import {ILendingPoolAddressesProvider, IProtocolDataProvider} from "../interfaces/IProtocolDataProvider.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IMultiFeeDistribution.sol";
import {IGeistIncentivesController} from "../interfaces/IGeistIncentivesController.sol";

interface IVariableDebtTokenX is IVariableDebtToken, IERC20 {}

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using SafeMath for uint8;

    uint256 private constant MAX_BPS = 10000;
    uint256 public minHealth;
    uint256 public minRebalanceAmount;

    uint256 public LEVERAGE;

    bool public constant isIncentivised = true;

    uint256 public minProfit;
    uint256 public minCredit;
    uint256 internal constant SECONDS_IN_YEAR = 365 days;

    IERC20 public constant geist = IERC20(0xd8321AA83Fb0a4ECd6348D4577431310A6E0814d);

    //Spookyswap as default
    IUniswapV2Router02 router;
    address weth;

    //Geist protocol config and providers
    ILendingPool pool;
    IPriceOracle oracle;
    IProtocolDataProvider public protocolDataProvider;
    ILendingPoolAddressesProvider provider;

    //Lend and debt tokens
    IAToken public aToken;
    IVariableDebtTokenX public dToken;

    event Cloned(address indexed clone);
    event Deleverage(bool full, uint256 amount);
    event DirectWithdraw(uint256 amount);

    constructor(address _vault) public BaseStrategy(_vault) {
        _initializeStrat();
    }

    function _initializeStrat() internal {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 6300;
        profitFactor = 1500;
        debtThreshold = 1_000_000 * 1e18;
        LEVERAGE = 5;
        //Derive required data from protocol data provider
        protocolDataProvider = IProtocolDataProvider(0xf3B0611e2E4D2cd6aB4bb3e01aDe211c3f42A8C3);
        _updateProtocolParams();

        //Spookyswap router
        router = IUniswapV2Router02(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
        weth = router.WETH();

        want.approve(address(pool), type(uint256).max);
        geist.approve(address(router), type(uint256).max);
    }

    function _updateProtocolParams() internal {
        //Set  specific params
        provider = ILendingPoolAddressesProvider(protocolDataProvider.ADDRESSES_PROVIDER());
        pool = ILendingPool(provider.getLendingPool());

        oracle = IPriceOracle(provider.getPriceOracle());

        minHealth = 1.08 ether; // 1.08 with 18 decimals this is slighly above 70% tvl
        minRebalanceAmount = 1 * 10**IERC20Extended(address(want)).decimals();
        DataTypes.ReserveData memory reserveData = pool.getReserveData(address(want));

        aToken = IAToken(reserveData.aTokenAddress);
        dToken = IVariableDebtTokenX(reserveData.variableDebtTokenAddress);
    }

    function updateProtocolParams() external onlyAuthorized {
        _updateProtocolParams();
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external {
        //note: initialise can only be called once. in _initialize in BaseStrategy we have: require(address(want) == address(0), "Strategy already initialized");
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat();
    }

    function cloneStrategy(address _vault) external returns (address newStrategy) {
        newStrategy = this.cloneStrategy(_vault, msg.sender, msg.sender, msg.sender);
    }

    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper);

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return "StrategyGeistLev";
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfDebt() public view returns (uint256) {
        //Return total debt of want in
        return dToken.balanceOf(address(this));
    }

    function getHealth() external view returns (uint256) {
        (
            ,
            ,
            ,
            ,
            /*uint256 totalCollateralETH*/
            /*uint256 totalDebtETH*/
            /*uint256 availableBorrowsETH*/
            /*uint256 currentLiquidationThreshold*/
            uint256 ltv,
            uint256 healthFactor
        ) = pool.getUserAccountData(address(this));
        return healthFactor;
    }

    function getMaxBorrowable() public view returns (uint256) {
        (
            ,
            ,
            ,
            ,
            /*uint256 totalCollateralETH*/
            /*uint256 totalDebtETH*/
            /*uint256 availableBorrowsETH*/
            /*uint256 currentLiquidationThreshold*/
            uint256 ltv,
            uint256 healthFactor
        ) = pool.getUserAccountData(address(this));

        if (healthFactor > minHealth) {
            // Amount = deposited * ltv - borrowed
            // Div MAX_BPS because because ltv / maxbps is the percent
            uint256 maxValue = balanceOfLend().mul(ltv).div(MAX_BPS).sub(balanceOfDebt());
            // Don't borrow if it's dust, save gas
            if (maxValue < minRebalanceAmount) {
                return 0;
            }

            return maxValue;
        }

        return 0;
    }

    function getMaxWithdrawable() public view returns (uint256) {
        // returns 95% of the collateral we can withdraw from aave, used to loop and repay debts
        (
            ,
            ,
            ,
            /*uint256 totalCollateralETH*/
            /*uint256 totalDebtETH*/
            /*uint256 availableBorrowsETH*/
            uint256 currentLiquidationThreshold,
            ,

        ) =
            /*uint256 ltv*/
            /*uint256 healthFactor*/
            pool.getUserAccountData(address(this));

        uint256 aBalance = balanceOfLend();
        uint256 vBalance = balanceOfDebt();

        if (vBalance == 0) {
            return type(uint256).max; //You have repaid all
        }

        uint256 diff = aBalance.sub(vBalance.mul(10000).div(currentLiquidationThreshold));
        uint256 inWant = diff.mul(97).div(100); // Take 97% just to be safe
        return inWant;
    }

    //Returns staked value
    function balanceOfLend() public view returns (uint256 total) {
        return aToken.balanceOf(address(this));
    }

    function getPositionValue() public view returns (uint256) {
        return balanceOfLend().sub(balanceOfDebt());
    }

    function getTokensForRewards() internal view returns (address[] memory _tokens) {
        _tokens = new address[](2);
        _tokens[0] = address(aToken);
        _tokens[1] = address(dToken);
    }

    function _sum(uint256[] memory array) internal view returns (uint256 total) {
        for (uint256 i = 0; i < array.length; i++) {
            total += array[i];
        }
    }

    function pendingGeistRewards() public view returns (uint256) {
        uint256[] memory rewards = _incentivesController().claimableReward(address(this), getTokensForRewards());
        return _sum(rewards).mul(5000).div(MAX_BPS);
    }

    //To track current loss from lev lending
    function pendingLoss() public view returns (uint256) {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 lendBal = estimatedTotalAssets();
        uint256 pendingGeistReward = _GEISTtoWant(pendingGeistRewards());
        uint256 totalAssets = pendingGeistReward + lendBal;
        if (debt > totalAssets) {
            //This will add to loss
            return debt.sub(totalAssets);
        }
    }

    function pendingLendingLoss() public view returns (uint256) {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 lendBal = estimatedTotalAssets();
        if (debt > lendBal) {
            //This will add to loss
            return debt.sub(lendBal);
        }
    }

    function pendingLendingProfit() public view returns (uint256) {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 lendBal = estimatedTotalAssets();
        uint256 totalAssets = lendBal;
        if (debt < totalAssets) {
            //This will add to profit
            return totalAssets.sub(debt);
        }
    }

    function getPNL() public view returns (uint256 profit, uint256 loss) {
        (profit, loss) = (pendingLendingProfit(), pendingLendingLoss());
    }

    function pendingProfit() public view returns (uint256) {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 lendBal = estimatedTotalAssets();
        uint256 pendingGeistReward = _GEISTtoWant(pendingGeistRewards());
        uint256 totalAssets = pendingGeistReward + lendBal;
        if (debt < totalAssets) {
            //This will add to profit
            return totalAssets.sub(debt);
        }
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the want balance and staked balance
        return balanceOfWant().add(getPositionValue());
    }

    function tendTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        return balanceOfWant() > minCredit;
    }

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        return pendingProfit() > minProfit || vault.creditAvailable() > minCredit;
    }

    function isLeveraged() public view returns (bool) {
        return LEVERAGE > 0;
    }

    function _GEISTtoWant(uint256 _amount) internal view returns (uint256) {
        return quote(address(geist), address(want), _amount);
    }

    function _incentivesController() internal view returns (IGeistIncentivesController) {
        if (isIncentivised) {
            return IGeistIncentivesController(address(aToken.getIncentivesController()));
        } else {
            return IGeistIncentivesController(0);
        }
    }

    // calculates APR from Liquidity Mining Program ,few helper functions taken from genlender aave and redone to work with geist
    function _incentivesRate(uint256 totalLiquidity, bool supplyIncentive) public view returns (uint256) {
        // only returns != 0 if the incentives are in place at the moment.
        // it will fail if the isIncentivised is set to true but there is no incentives
        if (isIncentivised) {
            uint256 _emissionsPerSecond;
            //Get total rewards per second
            _emissionsPerSecond = _incentivesController().rewardsPerSecond();
            (, uint256 alloc, , , ) =
                supplyIncentive ? _incentivesController().poolInfo(address(aToken)) : _incentivesController().poolInfo(address(dToken));
            //Readjust reward per second to incentive type/pool
            _emissionsPerSecond = _emissionsPerSecond.mul(alloc).div(_incentivesController().totalAllocPoint());
            //Calculate per second incentive for pool
            if (_emissionsPerSecond > 0) {
                uint256 emissionsInWant = _GEISTtoWant(_emissionsPerSecond); // amount of emissions in want

                uint256 incentivesRate = emissionsInWant.mul(SECONDS_IN_YEAR).mul(1e18).div(totalLiquidity); // APRs are in 1e18

                return incentivesRate.mul(4_750).div(10_000); // 47.50% of estimated APR to avoid overestimations,using 47.5 as its half of 95% since we exit early
            }
        }
        return 0;
    }

    function aprAfterDeposit(uint256 extraAmount) external view returns (uint256) {
        // i need to calculate new supplyRate after Deposit (when deposit has not been done yet)
        DataTypes.ReserveData memory reserveData = pool.getReserveData(address(want));

        (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt, , , , uint256 averageStableBorrowRate, , , ) =
            protocolDataProvider.getReserveData(address(want));

        uint256 newLiquidity = availableLiquidity.add(extraAmount);

        (, , , , uint256 reserveFactor, , , , , ) = protocolDataProvider.getReserveConfigurationData(address(want));

        (uint256 newLiquidityRate, , ) =
            IReserveInterestRateStrategy(reserveData.interestRateStrategyAddress).calculateInterestRates(
                address(want),
                newLiquidity,
                totalStableDebt,
                totalVariableDebt,
                averageStableBorrowRate,
                reserveFactor
            );

        uint256 incentivesRate = _incentivesRate(newLiquidity.add(totalStableDebt).add(totalVariableDebt), true); // total supplied liquidity in Aave v2
        return newLiquidityRate.div(1e9).add(incentivesRate); // divided by 1e9 to go from Ray to Wad
    }

    function _deposit(uint256 _depositAmount) internal {
        _depositToLending(_depositAmount);
        if (isLeveraged()) {
            _leverage();
        }
    }

    function _depositToLending(uint256 _depositAmount) internal {
        pool.deposit(address(want), _depositAmount, address(this), 0);
    }

    function _withdrawFromLending(uint256 _redeemAmount) internal {
        if (_redeemAmount > 0) pool.withdraw(address(want), _redeemAmount, address(this));
    }

    function _repay(uint256 _repayAmount) internal {
        if (_repayAmount > 0) pool.repay(address(want), _repayAmount, 2, address(this));
    }

    function _leverage() internal {
        for (uint256 i = 0; i < LEVERAGE; i++) {
            uint256 toBorrow = getMaxBorrowable();
            if (toBorrow > 0) {
                pool.borrow(address(want), toBorrow, 2, 0, address(this));
                pool.deposit(address(want), toBorrow, address(this), 0);
                toBorrow = getMaxBorrowable();
            } else {
                break;
            }
        }
    }

    // Base logic Taken from Tesseract,redone to simplify logic
    function _deleverageUpto(uint256 _reqAmount, bool fullDelev) internal {
        require(_reqAmount > 0, "ReqAmount < 0");
        uint256 borrowBal = balanceOfDebt();
        uint256 wantBal = balanceOfWant();
        uint256 maxWithdrawable = getPositionValue();
        uint256 withdrawable = getMaxWithdrawable();
        _reqAmount = Math.min(maxWithdrawable, _reqAmount);
        if (withdrawable != type(uint256).max && withdrawable > 0) {
            if (fullDelev) {
                while (withdrawable != type(uint256).max && withdrawable > 0) {
                    _withdrawAndRepay(withdrawable);
                    withdrawable = getMaxWithdrawable();
                }
                emit Deleverage(fullDelev, _reqAmount);
                uint256 lendBal = balanceOfLend();
                _withdrawFromLending(lendBal);
            } else {
                while (wantBal < _reqAmount && withdrawable > 0) {
                    //Withdraw and repay withdrawable amount
                    _withdrawAndRepay(withdrawable);
                    //withdraw from lending for max withdrawable
                    _withdrawFromLending(getMaxWithdrawable());
                    //Update temporary vars
                    wantBal = balanceOfWant();
                    withdrawable = getMaxWithdrawable();
                }
            }
        } else {
            emit DirectWithdraw(_reqAmount);
            _withdrawFromLending(_reqAmount);
        }
    }

    function _withdraw(uint256 _withdrawAmount) internal {
        if (isLeveraged() && getMaxWithdrawable() < _withdrawAmount) {
            _deleverageUpto(_withdrawAmount, _withdrawAmount >= getPositionValue());
        } else {
            _withdrawFromLending(_withdrawAmount);
        }
    }

    function withdrawAndRepay(uint256 _rAmount) external onlyAuthorized {
        _withdrawAndRepay(_rAmount);
    }

    function _withdrawAndRepay(uint256 _repayAmount) internal {
        _withdrawFromLending(_repayAmount);
        _repay(_repayAmount);
    }

    function updateMinProfit(uint256 _minProfit) external onlyStrategist {
        minProfit = _minProfit;
    }

    function updateMinCredit(uint256 _minCredit) external onlyStrategist {
        minCredit = _minCredit;
    }

    function updateLeverage(uint256 _newLev, bool rebalanceAfter) external onlyStrategist {
        LEVERAGE = _newLev;
        if (rebalanceAfter) {
            rebalance(getPositionValue());
        }
    }

    function updateRebalanceAmt(uint256 _newRebal) external onlyStrategist {
        minRebalanceAmount = _newRebal;
    }

    function updateMinHealth(uint256 _newHealth) external onlyStrategist {
        minHealth = _newHealth;
    }

    function _claimAndSwapRewards() internal {
        //Claim incentives from controller
        _incentivesController().claim(address(this), getTokensForRewards());
        //Early exit and swap
        IMultiFeeDistribution(_incentivesController().rewardMinter()).exit();
        _swapRewardsToWant();
    }

    function rebalance(uint256 amountToRebalance) public onlyAuthorized {
        _claimAndSwapRewards();
        liquidatePosition(amountToRebalance);
        _deposit(balanceOfWant());
    }

    function withdrawFromLending(uint256 amount) external onlyAuthorized {
        _withdraw(amount);
    }

    function returnDebtOutstanding(uint256 _debtOutstanding) internal returns (uint256 _debtPayment, uint256 _loss) {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }
    }

    function _swapRewardsToWant() internal {
        uint256 gBal = geist.balanceOf(address(this));
        if (gBal > 0) {
            router.swapExactTokensForTokens(gBal, 0, getTokenOutPath(address(geist), address(want)), address(this), block.timestamp);
        }
    }

    function handleProfit(uint256 _profit, uint256 _loss) internal returns (uint256, uint256) {
        uint256 balanceOfWantBefore = balanceOfWant();
        _claimAndSwapRewards();
        (uint256 p, uint256 l) = getPNL();
        _profit = _profit.add(p);
        _loss = _loss.add(l);
        return (_profit, _loss);
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        (_debtPayment, _loss) = returnDebtOutstanding(_debtOutstanding);
        (_profit, _loss) = handleProfit(_profit, _loss);
        uint256 balanceAfter = balanceOfWant();
        uint256 requiredWantBal = _profit + _debtPayment;
        if (balanceAfter < requiredWantBal) {
            //Withdraw enough to satisfy profit check
            _withdraw(requiredWantBal.sub(balanceAfter));
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();

        if (_debtOutstanding >= _wantAvailable) {
            return;
        }

        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);

        if (toInvest > 0) {
            _deposit(toInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 balanceWant = balanceOfWant();
        uint256 balanceStaked = getPositionValue();
        if (_amountNeeded > balanceWant) {
            uint256 amountToWithdraw = (Math.min(balanceStaked, _amountNeeded - balanceWant));
            _withdraw(amountToWithdraw);
        }
        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
        _loss = _amountNeeded > _liquidatedAmount ? _amountNeeded.sub(_liquidatedAmount) : 0;
    }

    function getTokenOutPath(address _token_in, address _token_out) internal view returns (address[] memory _path) {
        bool is_weth = _token_in == address(weth) || _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;
        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function quote(
        address _in,
        address _out,
        uint256 _amtIn
    ) internal view returns (uint256) {
        if (_amtIn <= 0) return _amtIn;
        address[] memory path = getTokenOutPath(_in, _out);
        return router.getAmountsOut(_amtIn, path)[path.length - 1];
    }

    function prepareMigration(address _newStrategy) internal override {
        _claimAndSwapRewards();
        liquidatePosition(type(uint256).max);
    }

    function liquidateAllPositions() internal virtual override returns (uint256 _amountFreed) {
        (_amountFreed, ) = liquidatePosition(type(uint256).max);
    }

    function fromETH(uint256 _amount, address asset) internal view returns (uint256) {
        return _amount.mul(uint256(10)**uint256(IERC20Extended(asset).decimals())).div(oracle.getAssetPrice(asset));
    }

    function _fromETH(uint256 _amount, address asset) internal view returns (uint256) {
        if (
            _amount == 0 || _amount == type(uint256).max || address(asset) == address(weth) // 1:1 change
        ) {
            return _amount;
        }
        return fromETH(_amount, asset);
    }

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256) {
        return _fromETH(_amtInWei, address(want));
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    function protectedTokens() internal view override returns (address[] memory) {}
}
