// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {IReserveInterestRateStrategy} from "@aave/contracts/interfaces/IReserveInterestRateStrategy.sol";
import {ILendingPool} from "@aave/contracts/interfaces/ILendingPool.sol";
import {IPriceOracle} from "@aave/contracts/interfaces/IPriceOracle.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {IVariableDebtToken} from "@aave/contracts/interfaces/IVariableDebtToken.sol";
import {ILendingPoolAddressesProvider, IProtocolDataProvider} from "../interfaces/IProtocolDataProvider.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./WadRayMath.sol";

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

interface IReserveInterestRateStrategyExt is IReserveInterestRateStrategy {
    function OPTIMAL_UTILIZATION_RATE() external view returns (uint256);

    function variableRateSlope1() external view returns (uint256);

    function variableRateSlope2() external view returns (uint256);

    function stableRateSlope1() external view returns (uint256);

    function stableRateSlope2() external view returns (uint256);
}
// Taken from yearnV2-aave-lender-borrower's AaveLenderBorrowerLib ,with unused extras removed
library AaveUtils {
    using SafeMath for uint256;
    using WadRayMath for uint256;
    uint256 constant _LTV_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000;

    struct CalcMaxDebtLocalVars {
        uint256 availableLiquidity;
        uint256 totalStableDebt;
        uint256 totalVariableDebt;
        uint256 totalDebt;
        uint256 utilizationRate;
        uint256 totalLiquidity;
        uint256 targetUtilizationRate;
        uint256 maxProtocolDebt;
    }

    struct IrsVars {
        uint256 optimalRate;
        uint256 baseRate;
        uint256 slope1;
        uint256 slope2;
    }

    uint256 internal constant MAX_BPS = 10_000;
    IProtocolDataProvider public constant protocolDataProvider = IProtocolDataProvider(0xf3B0611e2E4D2cd6aB4bb3e01aDe211c3f42A8C3);

    function lendingPool() public view returns (ILendingPool) {
        return ILendingPool(protocolDataProvider.ADDRESSES_PROVIDER().getLendingPool());
    }

    function priceOracle() public view returns (IPriceOracle) {
        return IPriceOracle(protocolDataProvider.ADDRESSES_PROVIDER().getPriceOracle());
    }

    /*
    function incentivesController(
        IAToken aToken,
        IVariableDebtToken variableDebtToken,
        bool isWantIncentivised,
        bool isInvestmentTokenIncentivised
    ) public view returns (IGeistIncentivesController) {
        if (isWantIncentivised) {
            return aToken.getIncentivesController();
        } else if (isInvestmentTokenIncentivised) {
            return variableDebtToken.getIncentivesController();
        } else {
            return IGeistIncentivesController(0);
        }
    }
*/
    function toETH(uint256 _amount, address asset) public view returns (uint256) {
        return _amount.mul(priceOracle().getAssetPrice(asset)).div(uint256(10)**uint256(IERC20Extended(asset).decimals()));
    }

    function fromETH(uint256 _amount, address asset) public view returns (uint256) {
        return _amount.mul(uint256(10)**uint256(IERC20Extended(asset).decimals())).div(priceOracle().getAssetPrice(asset));
    }

    function calcMaxDebt(address _investmentToken, uint256 _acceptableCostsRay)
        public
        view
        returns (
            uint256 currentProtocolDebt,
            uint256 maxProtocolDebt,
            uint256 targetU
        )
    {
        // This function is used to calculate the maximum amount of debt that the protocol can take
        // to keep the cost of capital lower than the set acceptableCosts
        // This maxProtocolDebt will be used to decide if capital costs are acceptable or not
        // and to repay required debt to keep the rates below acceptable costs

        // Hack to avoid the stack too deep compiler error.
        CalcMaxDebtLocalVars memory vars;
        DataTypes.ReserveData memory reserveData = lendingPool().getReserveData(address(_investmentToken));
        IReserveInterestRateStrategyExt irs = IReserveInterestRateStrategyExt(reserveData.interestRateStrategyAddress);

        (
            vars.availableLiquidity, // = total supply - total stable debt - total variable debt
            vars.totalStableDebt, // total debt paying stable interest rates
            vars.totalVariableDebt, // total debt paying stable variable rates
            ,
            ,
            ,
            ,
            ,
            ,

        ) = protocolDataProvider.getReserveData(address(_investmentToken));

        vars.totalDebt = vars.totalStableDebt.add(vars.totalVariableDebt);
        vars.totalLiquidity = vars.availableLiquidity.add(vars.totalDebt);
        vars.utilizationRate = vars.totalDebt == 0 ? 0 : vars.totalDebt.rayDiv(vars.totalLiquidity);

        // Aave's Interest Rate Strategy Parameters (see docs)
        IrsVars memory irsVars;
        irsVars.optimalRate = irs.OPTIMAL_UTILIZATION_RATE();
        irsVars.baseRate = irs.baseVariableBorrowRate(); // minimum cost of capital with 0 % of utilisation rate
        irsVars.slope1 = irs.variableRateSlope1(); // rate of increase of cost of debt up to Optimal Utilisation Rate
        irsVars.slope2 = irs.variableRateSlope2(); // rate of increase of cost of debt above Optimal Utilisation Rate

        // acceptableCosts should always be > baseVariableBorrowRate
        // If it's not this will revert since the strategist set the wrong
        // acceptableCosts value
        if (vars.utilizationRate < irsVars.optimalRate && _acceptableCostsRay < irsVars.baseRate.add(irsVars.slope1)) {
            // we solve Aave's Interest Rates equation for sub optimal utilisation rates
            // IR = BASERATE + SLOPE1 * CURRENT_UTIL_RATE / OPTIMAL_UTIL_RATE
            vars.targetUtilizationRate = (_acceptableCostsRay.sub(irsVars.baseRate)).rayMul(irsVars.optimalRate).rayDiv(irsVars.slope1);
        } else {
            // Special case where protocol is above utilization rate but we want
            // a lower interest rate than (base + slope1)
            if (_acceptableCostsRay < irsVars.baseRate.add(irsVars.slope1)) {
                return (toETH(vars.totalDebt, address(_investmentToken)), 0, 0);
            }

            // we solve Aave's Interest Rates equation for utilisation rates above optimal U
            // IR = BASERATE + SLOPE1 + SLOPE2 * (CURRENT_UTIL_RATE - OPTIMAL_UTIL_RATE) / (1-OPTIMAL_UTIL_RATE)
            vars.targetUtilizationRate = (_acceptableCostsRay.sub(irsVars.baseRate.add(irsVars.slope1)))
                .rayMul(uint256(1e27).sub(irsVars.optimalRate))
                .rayDiv(irsVars.slope2)
                .add(irsVars.optimalRate);
        }

        vars.maxProtocolDebt = vars.totalLiquidity.rayMul(vars.targetUtilizationRate).rayDiv(1e27);

        return (
            toETH(vars.totalDebt, address(_investmentToken)),
            toETH(vars.maxProtocolDebt, address(_investmentToken)),
            vars.targetUtilizationRate
        );
    }

    function calculateAmountToRepay(
        uint256 amountETH,
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 warningLTV,
        uint256 targetLTV,
        address investmentToken,
        uint256 minThreshold
    ) public view returns (uint256) {
        if (amountETH == 0) {
            return 0;
        }
        // we check if the collateral that we are withdrawing leaves us in a risky range, we then take action
        uint256 amountToWithdrawETH = amountETH;
        // calculate the collateral that we are leaving after withdrawing
        uint256 newCollateral = totalCollateralETH > amountToWithdrawETH ? totalCollateralETH.sub(amountToWithdrawETH) : 0;
        uint256 ltvAfterWithdrawal = newCollateral > 0 ? totalDebtETH.mul(MAX_BPS).div(newCollateral) : type(uint256).max;
        // check if the new LTV is in UNHEALTHY range
        // remember that if balance > _amountNeeded, ltvAfterWithdrawal == 0 (0 risk)
        // this is not true but the effect will be the same
        if (ltvAfterWithdrawal <= warningLTV) {
            // no need of repaying debt because the LTV is ok
            return 0;
        } else if (ltvAfterWithdrawal == type(uint256).max) {
            // we are withdrawing 100% of collateral so we need to repay full debt
            return fromETH(totalDebtETH, address(investmentToken));
        }
        // WARNING: this only works for a single collateral asset, otherwise liquidationThreshold might change depending on the collateral being withdrawn
        // e.g. we have USDC + WBTC as collateral, end liquidationThreshold will be different depending on which asset we withdraw
        uint256 newTargetDebt = targetLTV.mul(newCollateral).div(MAX_BPS);
        // if newTargetDebt is higher, we don't need to repay anything
        if (newTargetDebt > totalDebtETH) {
            return 0;
        }
        return
            fromETH(totalDebtETH.sub(newTargetDebt) < minThreshold ? totalDebtETH : totalDebtETH.sub(newTargetDebt), address(investmentToken));
    }

    function shouldRebalance(
        address investmentToken,
        uint256 acceptableCostsRay,
        uint256 targetLTV,
        uint256 warningLTV,
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 maxGasPriceToTend
    ) external view returns (bool) {
        uint256 currentLTV = totalDebtETH.mul(MAX_BPS).div(totalCollateralETH);

        (uint256 currentProtocolDebt, uint256 maxProtocolDebt, ) = calcMaxDebt(investmentToken, acceptableCostsRay);

        // If we are in danger zone then repay debt regardless of the current gas price
        if (currentLTV > warningLTV) {
            return true;
        }

        if (
            (currentLTV < targetLTV && currentProtocolDebt < maxProtocolDebt && targetLTV.sub(currentLTV) > 1000) || // WE NEED TO TAKE ON MORE DEBT (we need a 10p.p (1000bps) difference)
            (currentProtocolDebt > maxProtocolDebt) // UNHEALTHY BORROWING COSTS
        ) {
            // return baseFeeProvider.basefee_global() <= maxGasPriceToTend;
        }

        // no call to super.tendTrigger as it would return false
        return false;
    }

    //Based from FixedForex code
    function _getParamsMemory(DataTypes.ReserveConfigurationMap memory self) internal pure returns (uint256) {
        return (self.data & ~_LTV_MASK);
    }

    function _getLTVAaveV2(ILendingPool pool, address token) internal view returns (uint256 ltv) {
        ltv = _getParamsMemory(pool.getConfiguration(token));
    }
}
